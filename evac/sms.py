"""SMS as the text channel (Twilio): MuZip on a phone or a Mac texts the MuZip number, and this replies.

A photo travels as many code parts (evac/codes.py, one SMS each), and a phone sends them in a few texts, so this keeps
each sender's texts until every code in them is complete, then hands them to the router as one message (the question
in plain words, the codes beside it). If parts are still missing WAIT seconds after the last text, it asks the phone
for them ("RESEND <id> <part>..."), and MuZip sends them again.

Every reply starts "MuZip: " and the first reply to each question ends its words with "Reply STOP to opt out." (what
the number's registration describes). STOP, HELP and START are answered by Twilio's opt-out handling, not here.

Twilio posts every incoming text to POST /sms on the bridge (sim/whatsapp_server.py). .env: TWILIO_ACCOUNT_SID,
TWILIO_AUTH_TOKEN, PUBLIC_URL (as for WhatsApp), SMS_FROM (the MuZip number, e.g. +17372583742). Without credentials,
replies only go to OUTBOX (what tests read).
"""
import threading
import time
import traceback
from concurrent.futures import ThreadPoolExecutor

import requests

from . import codes, router, store
from .whatsapp import _env, _split

WAIT = 90                # seconds after a sender's last text before asking again for missing parts
STOP_LINE = "Reply STOP to opt out."
OUTBOX = []
_pending = {}            # who -> {"texts": [...], "timer": Timer}
_lock = threading.Lock()
_pool = ThreadPoolExecutor(4)


def log(who, direction, body):
    store.new("sms_msg", who=who, meta={"dir": direction, "body": body, "at": time.time()})


def send(to, body):
    for chunk in _split(body):
        log(to, "out", chunk)
        if not (_env("TWILIO_ACCOUNT_SID") and _env("TWILIO_AUTH_TOKEN") and _env("SMS_FROM")):
            OUTBOX.append({"to": to, "body": chunk, "at": time.time()})
            continue
        r = requests.post("https://api.twilio.com/2010-04-01/Accounts/%s/Messages.json" % _env("TWILIO_ACCOUNT_SID"),
                          data={"From": _env("SMS_FROM"), "To": to, "Body": chunk},
                          auth=(_env("TWILIO_ACCOUNT_SID"), _env("TWILIO_AUTH_TOKEN")), timeout=30)
        if r.status_code >= 300:
            print("twilio refused a text:", r.status_code, r.text[:300], flush=True)


def incoming(params):
    """A text Twilio posted (its form fields). Returns at once; the work happens in the background."""
    _pool.submit(_safe, params.get("From", ""), (params.get("Body") or "").strip())


def _safe(who, body):
    try:
        take(who, body)
    except Exception as ex:
        traceback.print_exc()
        send(who, "MuZip: Sorry, something went wrong on my side (%s). Please try again." % type(ex).__name__)


def take(who, body):
    """One text from `who`: kept with their earlier ones until its codes are complete, then answered."""
    log(who, "in", body)
    with _lock:
        p = _pending.setdefault(who, {"texts": [], "timer": None})
        p["texts"].append(body)
        message = "\n".join(p["texts"])
        if p["timer"]:
            p["timer"].cancel()
            p["timer"] = None
        found = codes.decode(message)
        if found["missing"] and not codes.RESEND.search(message):
            p["timer"] = threading.Timer(WAIT, _ask_again, (who,))
            p["timer"].daemon = True
            p["timer"].start()
            return None
        del _pending[who]
    out = router.handle(message, who=who)
    asked = not any(c["kind"] == "Z" for c in found["complete"])  # not a close-up: a new question, so its first reply
    text = words(out.get("text") or "I couldn't work that out.", first=asked)
    send(who, text)
    return text


def _ask_again(who):
    with _lock:
        p = _pending.get(who)
        if not p:
            return
        p["timer"] = None
        missing = codes.decode("\n".join(p["texts"]))["missing"]
    for ident, parts in missing.items():
        send(who, "MuZip: Some parts didn't arrive.\nRESEND %s %s" % (ident, " ".join(map(str, sorted(parts)))))


def words(text, first=False):
    """A reply as the number sends it: "MuZip: " first, and on the first reply to a question the STOP line after its
    words (before any ZOOM lines, which MuZip reads)."""
    lines = text.strip().split("\n")
    if first:
        at = next((i for i, line in enumerate(lines) if codes.ZOOM.match(line.strip())), len(lines))
        if at:
            lines[at - 1] = lines[at - 1].rstrip() + " " + STOP_LINE
        else:
            lines.insert(0, STOP_LINE)
    return "MuZip: " + "\n".join(lines)
