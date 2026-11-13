"""MuZip on public benchmarks (evals/bench/fetch.py downloads them): how often it is right, and how many bytes it
needed, against the photo sent whole and the photo squeezed by WebP into the same bytes.

  vstar     V* Bench: small things in ~2,250 px photos (multiple choice)
  hrbench   HR-Bench 4K: details in 4K photos (multiple choice)
  textvqa   TextVQA: reading text in 1,024 px photos (open answers)

Ways:
  muzip  the loop (evac/closer.py) through the router, a simulated phone keeping the original
  full   the photo as Muse normally gets it (JPEG, at most 2,048 px), one look
  webp   the whole photo in WebP at the bytes MuZip used on that question, one look
  webp@N the whole photo in WebP at N bytes (for the bytes-vs-right curve)

Scoring needs no judge. Multiple choice: the option the answer names, against the label. Open (TextVQA): VQA
accuracy, min(1, humans who gave that answer / 3), an answer matching a human answer when, normalised, it equals it
or contains it as whole words (Muse answers in a sentence). Split: each kind is split in half by a hash of the
question id into "dev" (tune on it) and "test" (report it; don't read its failures while tuning).

Results are kept per question in out/eval/bench/<set>/<way>/<tag>/; the tag is a hash of the loop's code, plus the
limits when they aren't the loop's own, so an unchanged loop re-runs for free.

    .venv/bin/python evals/bench/run.py --set vstar --split dev --limit 6           # a smoke test
    .venv/bin/python evals/bench/run.py --set vstar,hrbench,textvqa --ways muzip,full,webp
    .venv/bin/python evals/bench/run.py --set vstar --max-views 16 --budget 480     # more looks
    .venv/bin/python evals/bench/run.py --set vstar --side 256 --high 512 --budget 640  # sharper pictures
    .venv/bin/python evals/bench/run.py --set vstar --ways webp@4000,webp@16000,webp@64000 --curve
"""
import argparse
import hashlib
import json
import os
import re
import statistics
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "sim"))
sys.path.insert(0, os.path.join(ROOT, "evals", "kit"))
from PIL import Image  # noqa: E402

import three_ways  # noqa: E402
from evac import closer, codes, llm, router, smsimage, store  # noqa: E402
from phones import Phone  # noqa: E402

CACHE = os.path.join(ROOT, "cache", "bench")
OUT = os.path.join(ROOT, "out", "eval", "bench")
SETS = ("vstar", "hrbench", "textvqa")
LOOP = ["evac/closer.py", "evac/codes.py", "evac/smsimage.py", "evac/router.py", "evac/sam.py", "evac/llm.py"]
RUNNER = "1"  # bump when muzip() changes what it records (this script is left out of the hash, so reports can change)
DEFAULT = (smsimage.SIDE, codes.HIGH, closer.MAX_VIEWS, closer.BUDGET)  # the loop as it ships
ASK_LETTER = "Reply with the letter and the option, for example \"(B) red\"."
ASK_OPEN = "Reply with just the answer, in a few words."
SEEN = 16  # a target this many pixels long in some close-up counts as seen (V*: right 85% when seen, 27% when not)


def loop_hash():
    h = hashlib.sha1(RUNNER.encode())
    for f in LOOP:
        with open(os.path.join(ROOT, f), "rb") as fh:
            h.update(fh.read())
    return h.hexdigest()[:10]


def tag_for(side, high, views, budget):
    """Where a MuZip setting's results go: the loop's hash, plus the setting when it isn't the loop's own."""
    if (side, high, views, budget) == DEFAULT:
        return loop_hash()
    return loop_hash() + "-s%d-h%d-v%d-b%d" % (side, high, views, budget)


def load(name):
    with open(os.path.join(CACHE, name, "questions.jsonl")) as f:
        rows = [json.loads(line) for line in f if line.strip()]
    for r in rows:
        r["set"] = name
        if "options" in r:
            r["prompt"] = "\n".join([r["question"]] + ["(%s) %s" % tuple(o) for o in r["options"]] + [ASK_LETTER])
        else:
            r["prompt"] = r["question"] + "\n" + ASK_OPEN
    by_kind = {}
    for r in sorted(rows, key=lambda r: hashlib.sha1(r["id"].encode()).hexdigest()):
        by_kind.setdefault(r["kind"], []).append(r)
    for same in by_kind.values():
        for i, r in enumerate(same):
            r["split"] = "dev" if i % 2 == 0 else "test"
    return rows


def letter(answer, options):
    """The option an answer picked: "(B)", "B)" or "B." at the start, or else the one option whose words it uses."""
    a = answer.strip()
    m = re.search(r"\(([A-D])\)", a) or re.match(r"^([A-D])[).:\s]", a + " ")
    if m and m.group(1) in dict(options):
        return m.group(1)
    hits = [k for k, text in options if re.search(r"\b%s\b" % re.escape(text.lower()), a.lower())]
    return hits[0] if len(hits) == 1 else None


NUMBERS = {w: str(i) for i, w in enumerate("zero one two three four five six seven eight nine ten".split())}


def norm(s):
    s = re.sub(r"[^\w\s]", " ", str(s).lower())
    return " ".join(NUMBERS.get(w, w) for w in s.split() if w not in ("a", "an", "the"))


def vqa(answer, humans):
    """VQA accuracy of a sentence-long answer against the ten human answers."""
    a = norm(answer)
    best = 0.0
    for h in set(humans):
        n = norm(h)
        if n and (a == n or re.search(r"(^| )%s( |$)" % re.escape(n), a)):
            best = max(best, min(1.0, sum(norm(x) == n for x in humans) / 3))
    return best


def score(item, answer):
    """-> (what it picked, score 0..1)"""
    if "options" in item:
        pick = letter(answer, item["options"])
        return pick, float(pick == item["label"])
    return None, vqa(answer, item["answers"])


def covered(boxes, targets, scale):
    """For each target box ([x, y, w, h] in photo px): the sharpest close-up holding at least half of it, as (share
    of the target inside it, the target's long side in that close-up's pixels); (0, 0) when none does. Close-up boxes
    are in the sketch's pixels; `scale` is photo pixels per sketch pixel."""
    out = []
    for x, y, w, h in targets:
        best = (0.0, 0.0)
        for v in boxes:
            bx, by, bw, bh = [c * scale for c in v["box"]]
            inside = max(0, min(x + w, bx + bw) - max(x, bx)) * max(0, min(y + h, by + bh) - max(y, by)) / max(1, w * h)
            if inside >= 0.5:
                best = max(best, (round(inside, 2), round(v["side"] / max(bw, bh) * max(w, h), 1)), key=lambda c: c[1])
        out.append(best)
    return out


def seen(item, r):
    """Every target got a close-up showing it at SEEN px or more (None when the set has no target boxes)."""
    if not item.get("targets"):
        return None
    c = covered(r.get("boxes", []), item["targets"], r.get("scale", 1))
    return min(x[1] for x in c) >= SEEN


def muzip(item, img, n):
    """The loop, as evals/kit/three_ways.muzip_run runs it, keeping what the benchmark needs."""
    phone = Phone("+15550%06d" % n, lambda who, text: phone.got(router.handle(text, three_ways.HERE, who=who)["text"]), delay=0)
    replies = []
    got = phone.got
    phone.got = lambda text: (replies.append(text), got(text))[1]
    phone.text(item["prompt"] + "\n" + codes.text(phone.picture(img)))
    sent = [c for m in phone.outbox for c in codes.decode(m)["complete"]]
    inq = next((r for r in store.find("inquiry") if r["who"] == phone.who), None)
    meta = (inq or {}).get("meta", {})
    views = [v for v in meta.get("views", []) if v.get("zoom")]
    return {"answer": meta.get("answer") or (replies[-1] if replies else ""), "sure": meta.get("sure") or "no",
            "texts": sum(codes.sms_parts(m) for m in phone.outbox), "bytes": sum(len(c["data"]) for c in sent), "views": len(views),
            "boxes": [dict(box=v["got_box"], colour=v["colour"], high=v.get("high", False), side=max(store.image(v["zoom"]).size),
                           object=v.get("object", "")) for v in views],
            "scale": img.size[0] / meta["pic"]["size"][0] if meta else 0}


def one_look(item, shown):
    try:
        d = llm.chat_json([{"role": "user", "content": [{"type": "text", "text": three_ways.ASK.format(question=item["prompt"])}, llm.image_part(*shown)]}])
        return {"answer": str(d.get("answer") or ""), "sure": str(d.get("sure") or "no")}
    except Exception as ex:
        return {"answer": "(error: %s)" % str(ex)[:80], "sure": "no"}


def webp_at(img, budget):
    """The whole photo in colour WebP within `budget` bytes: the widest side that fits at quality 20 or more, else
    the best quality at the smallest side."""
    sides = sorted({128, 192, 256, 384, 512, 768, 1024, 1536, 2048})
    cands = []
    for side in sides:
        fits = [q for q in (90, 75, 60, 45, 30, 20, 10, 5, 1) if len(three_ways.webp(img, side, q, True)) <= budget]
        if fits:
            cands.append((side, fits[0]))
    if not cands:
        return None
    good = [c for c in cands if c[1] >= 20]
    side, q = max(good) if good else max(cands, key=lambda c: c[1])
    return three_ways.webp(img, side, q, True), {"side": side, "quality": q}


def run_one(way, item, tag, n):
    d = os.path.join(OUT, item["set"], way, tag)
    path = os.path.join(d, item["id"] + ".json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    img = Image.open(os.path.join(CACHE, item["set"], item["image"])).convert("RGB")
    t = time.time()
    try:
        if way == "muzip":
            r = muzip(item, img, n)
        elif way == "full":
            data = three_ways.full_view(img)
            r = dict(one_look(item, data), bytes=len(data[0]))
        else:
            budget = int(way.split("@")[1]) if "@" in way else item["_muzip_bytes"]
            w = webp_at(img, budget)
            r = {"answer": "(nothing fits)", "sure": "no", "bytes": 0} if w is None else dict(one_look(item, (w[0], "webp")), bytes=len(w[0]), webp=w[1])
    except Exception as ex:
        r = {"answer": "(error: %s)" % str(ex)[:120], "sure": "no", "bytes": 0}
    r["picked"], r["score"] = score(item, r["answer"])
    r.update(id=item["id"], kind=item["kind"], seconds=round(time.time() - t, 1))
    os.makedirs(d, exist_ok=True)
    with open(path, "w") as f:
        json.dump(r, f)
    return r


def report(way, items, rows):
    lines = []
    kinds = sorted({it["kind"] for it in items})
    for kind in kinds + [None]:
        part = [(it, r) for it, r in zip(items, rows) if kind is None or it["kind"] == kind]
        if not part or (kind and len(kinds) == 1):
            continue
        sc = [r["score"] for _, r in part]
        sure = [r["score"] for _, r in part if r["sure"] == "yes"]
        line = "  %-9s %-18s right %5.1f/%-3d (%3.0f%%)  sure %3d, right when sure %3.0f%%  median bytes %6d" % (
            way, kind or "all", sum(sc), len(sc), 100 * sum(sc) / len(sc), len(sure), 100 * sum(sure) / max(1, len(sure)),
            statistics.median(r.get("bytes", 0) for _, r in part))
        if way == "muzip":
            line += "  texts %g  close-ups %g" % (statistics.median(r.get("texts", 0) for _, r in part), statistics.median(r.get("views", 0) for _, r in part))
            s = [(seen(it, r), r["score"]) for it, r in part]
            if s[0][0] is not None:
                hit = [x for ok, x in s if ok]
                miss = [x for ok, x in s if not ok]
                line += "  target seen at %d px+ %d%% (right when seen %2.0f%%, not %2.0f%%)" % (
                    SEEN, 100 * len(hit) / len(s), 100 * sum(hit) / max(1, len(hit)), 100 * sum(miss) / max(1, len(miss)))
        lines.append(line)
    if any("options" in it for it in items):
        unparsed = sum(r["picked"] is None for r in rows)
        if unparsed:
            lines.append("  %-9s %d answers named no option" % (way, unparsed))
    return "\n".join(lines)


def curve(items, results):
    """Share right with at most B bytes sent: an answer that took more than B counts as wrong. For MuZip this reads one
    run at a time cut-off (it would have answered differently with less, so it is an estimate); for webp@N it is N."""
    levels = [2000, 4000, 8000, 16000, 32000, 64000, 128000]
    lines = ["  %-9s %s" % ("bytes <=", " ".join("%7d" % b for b in levels))]
    for way, rows in results.items():
        if way == "full":
            continue
        vals = [100 * sum(r["score"] for r in rows if r.get("bytes", 0) <= b) / len(rows) for b in levels]
        lines.append("  %-9s %s" % (way, " ".join("%6.0f%%" % v for v in vals)))
    return "\n".join(lines)


def main():
    a = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    a.add_argument("--set", default="vstar", help="comma-separated: " + ", ".join(SETS))
    a.add_argument("--split", choices=["dev", "test", "all"], default="dev")
    a.add_argument("--ways", default="muzip", help="comma-separated: muzip, full, webp (needs muzip), webp@N")
    a.add_argument("--limit", type=int, help="only N questions of each set (split evenly across its kinds)")
    a.add_argument("--side", type=int, default=DEFAULT[0], help="px of the sketch and a normal close-up (smsimage.SIDE)")
    a.add_argument("--high", type=int, default=DEFAULT[1], help="px of a high-detail close-up (codes.HIGH)")
    a.add_argument("--max-views", type=int, default=DEFAULT[2], help="close-ups Muse may ask for (closer.MAX_VIEWS)")
    a.add_argument("--budget", type=int, default=DEFAULT[3], help="texts the phone may send in all (closer.BUDGET)")
    a.add_argument("--curve", action="store_true", help="print the bytes-vs-right curve")
    a.add_argument("--workers", type=int, default=24)
    args = a.parse_args()
    smsimage.SIDE, codes.HIGH, closer.MAX_VIEWS, closer.BUDGET = args.side, args.high, args.max_views, args.budget
    tag = tag_for(args.side, args.high, args.max_views, args.budget)
    ways = args.ways.split(",")
    store.use(tempfile.mkdtemp())
    t = time.time()
    for k, name in enumerate(args.set.split(",")):
        items = [it for it in load(name) if args.split == "all" or it["split"] == args.split]
        if args.limit:
            kinds = sorted({it["kind"] for it in items})
            items = [it for kind in kinds for it in [x for x in items if x["kind"] == kind][:max(1, args.limit // len(kinds))]]
        print("%s, %s split: %d questions; loop %s" % (name, args.split, len(items), tag), flush=True)
        results = {}
        with ThreadPoolExecutor(args.workers) as pool:
            if "muzip" in ways or "webp" in ways:
                results["muzip"] = list(pool.map(lambda p: run_one("muzip", p[1], tag, 100000 * k + p[0]), enumerate(items)))
            if "full" in ways:
                results["full"] = list(pool.map(lambda it: run_one("full", it, "v1", 0), items))
            if "webp" in ways:
                for it, m in zip(items, results["muzip"]):
                    it["_muzip_bytes"] = max(1, m["bytes"])
                results["webp"] = list(pool.map(lambda it: run_one("webp", it, tag, 0), items))
            for way in ways:
                if way.startswith("webp@"):
                    results[way] = list(pool.map(lambda it: run_one(way, it, "v1", 0), items))
        for way in ways:
            print(report(way, items, results[way]))
        if args.curve:
            print(curve(items, results))
    print("%.0f s" % (time.time() - t))


if __name__ == "__main__":
    main()
