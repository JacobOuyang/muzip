"""The simulator: pages that show the look-closer loop with a simulated phone, and the API behind them.

    .venv/bin/python sim/server.py            # http://localhost:8765

Pages: /closer (a phone asks about a photo it keeps; the real router, Muse Spark and SAM 3.1 answer, asking the phone
for close-ups; ?device=drone names the device), /compare (one photo and question three ways: the photo, WebP at the
loop's size, the loop; from the last run of evals/kit/three_ways.py, else the copy in demo/three_ways/), /group (a
simulated WhatsApp group with Muse in it), /demo (the video's stage: every scene, step by step).

Look closer: GET /api/closer/samples, /api/closer/state?c=; POST /api/closer/start {"sample", "question"}
Also: GET /api/compare, /kit.js (the code reader the pages use), /store/<record id>.jpg, /eval/three_ways/<file>.png
"""
import io
import json
import os
import sys
import traceback
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ROOT, ".."))
sys.path.insert(0, ROOT)
from evac import codes, llm, router, store  # noqa: E402
import closer_demo  # noqa: E402  (a phone asks about a photo it keeps)
import group_demo  # noqa: E402  (a WhatsApp group with Muse in it, simulated)

PORT = int(os.environ.get("PORT", 8765))
PAGES = {"/": "demo.html", "/demo": "demo.html", "/closer": "closer.html", "/compare": "compare.html", "/group": "group.html"}
EVAL = os.path.join(ROOT, "..", "out", "eval")
if not os.path.exists(os.path.join(EVAL, "three_ways", "results.json")):  # a fresh clone: the measured run kept with the demo
    EVAL = os.path.join(ROOT, "..", "demo")


def jpeg(img, side, quality):
    img = img.convert("RGB")
    img.thumbnail((side, side))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality)
    return buf.getvalue()


def kit_js():
    """The code reader with its phrasebook and the issuer's public key in front."""
    return ("var KIT_PUBKEY = %s;\nvar KIT_PACK = %s;\n" % (json.dumps(codes.public_key()), json.dumps(codes.pack())) +
            open(os.path.join(ROOT, "kit.js")).read())


def compare_rows():
    """The last run of evals/kit/three_ways.py, for /compare."""
    p = os.path.join(EVAL, "three_ways", "results.json")
    return {"rows": json.load(open(p)) if os.path.exists(p) else []}


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def send_bytes(self, data, kind, code=200):
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, obj, code=200):
        self.send_bytes(json.dumps(obj).encode(), "application/json", code)

    def do_GET(self):
        path, _, query = self.path.partition("?")
        arg = unquote(query.split("=", 1)[1]) if "=" in query else ""
        if path in PAGES:
            return self.send_bytes(open(os.path.join(ROOT, PAGES[path]), "rb").read(), "text/html; charset=utf-8")
        if path == "/kit.js":
            return self.send_bytes(kit_js().encode(), "application/javascript; charset=utf-8")
        if path.startswith("/store/") and path.endswith(".jpg"):  # a record's picture (a phone's 128 px photo, a close-up)
            img = store.image(path[len("/store/"):-4])
            return self.send_bytes(jpeg(img, 640, 88), "image/jpeg") if img else self.send_error(404)
        if path == "/api/group/sketch":  # the 128 px sketch the group got
            return self.send_bytes(group_demo.sketch_png(arg), "image/png")
        if path.startswith("/eval/three_ways/") and path.endswith(".png") and ".." not in path:
            p = os.path.join(EVAL, path[len("/eval/"):])
            return self.send_bytes(open(p, "rb").read(), "image/png") if os.path.exists(p) else self.send_error(404)
        if path == "/api/phone/replies":  # for MuZip on a Mac: what the bridge sent a number (WhatsApp or SMS) since a time
            q = dict(kv.split("=", 1) for kv in query.split("&") if "=" in kv)
            return self.send_json({"replies": phone_replies(unquote(q.get("to", "")), float(q.get("after") or 0))})
        api = {"/api/closer/samples": lambda: {"samples": closer_demo.samples()},
               "/api/closer/state": lambda: closer_demo.state(arg),
               "/api/compare": compare_rows,
               "/api/group/state": lambda: group_demo.state(arg)}
        if path in api:
            return self.send_json(api[path]())
        return super().do_GET()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        try:
            if self.path == "/api/phone/ask":  # MuZip on a Mac, "simulated": a message straight to the router, no texts
                return self.send_json({"text": router.handle(body.get("text", ""), who=body.get("who") or "mac:sim").get("text") or ""})
            if self.path == "/api/closer/start":  # a simulated phone asks about one of the sample photos
                return self.send_json({"conv": closer_demo.start(body["sample"], body.get("question") or "What is this?")})
            if self.path == "/api/group/start":  # a group member shares a sample photo
                return self.send_json({"conv": group_demo.start(body["sample"])})
            if self.path == "/api/group/ask":
                return self.send_json({"error": group_demo.ask(body["conv"], body["who"], body["question"])})
            self.send_json({"error": "not found"}, 404)
        except Exception as ex:
            traceback.print_exc()
            self.send_json({"error": "%s: %s" % (type(ex).__name__, ex)}, 500)


def phone_replies(to, after):
    """Messages the bridge sent to `to` (or, if empty, to your own WhatsApp: MY_WHATSAPP) after time `after`, oldest
    first: how MuZip on a Mac reads Muse's WhatsApp replies without reading WhatsApp."""
    if not to:
        n = os.environ.get("MY_WHATSAPP", "").strip()
        to = n if n.startswith("whatsapp:") else "whatsapp:+" + n.lstrip("+")
    rows = [r for kind in ("wa_msg", "sms_msg") for r in store.find(kind, since=after - 5, limit=200)]
    out = [{"at": r["meta"]["at"], "body": r["meta"]["body"]} for r in rows
           if r["who"] == to and r["meta"].get("dir") == "out" and r["meta"].get("at", 0) > after]
    return sorted(out, key=lambda m: m["at"])


if __name__ == "__main__":
    llm._load_dotenv()
    print("simulator on http://127.0.0.1:%d (model %s)" % (PORT, "on" if llm.available() else "off: set LLAMA_API_KEY in .env"), flush=True)
    ThreadingHTTPServer((os.environ.get("SIM_HOST", "127.0.0.1"), PORT), Handler).serve_forever()
