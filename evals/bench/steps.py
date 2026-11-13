"""Where MuZip looked, question by question, printed (nothing is written): each close-up the loop got as
percentages of the photo ([left top right bottom]; N normal, H high detail, C colour), the target's box where the set
has one (V*), the answer, its score, and an outcome:

  right        scored 1
  missed       (V*) no close-up showed every target at run.SEEN px or more: the search failed
  misread      wrong, with the target seen (or no target boxes)
  abstained    named no option / matched no human answer, and said it couldn't tell

    .venv/bin/python evals/bench/steps.py --set vstar                     # the current loop's dev results
    .venv/bin/python evals/bench/steps.py --set hrbench --tag 4ebe691e6d-v16-b480 --only missed,abstained
"""
import argparse
import collections
import json
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run  # noqa: E402

OUTCOMES = ("right", "missed", "misread", "abstained")


def outcome(item, r):
    if r["score"] >= 1:
        return "right"
    if run.seen(item, r) is False:
        return "missed"
    cant = r["sure"] == "no" and ("can't" in r["answer"].lower() or "cannot" in r["answer"].lower())
    return "abstained" if cant or (r.get("picked") is None and "options" in item) else "misread"


def pct(box, W, H):
    l, t, w, h = box
    return "[%d %d %d %d]" % (100 * l / W, 100 * t / H, 100 * (l + w) / W, 100 * (t + h) / H)


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--set", default="vstar")
    a.add_argument("--split", default="dev")
    a.add_argument("--tag", help="a results tag under out/eval/bench/<set>/muzip/ (default: the current loop's)")
    a.add_argument("--only", help="outcomes to list, comma-separated")
    args = a.parse_args()
    src = os.path.join(run.OUT, args.set, "muzip", args.tag or run.loop_hash())
    counts = collections.Counter()
    for it in run.load(args.set):
        p = os.path.join(src, it["id"] + ".json")
        if (args.split != "all" and it["split"] != args.split) or not os.path.exists(p):
            continue
        with open(p) as f:
            r = json.load(f)
        o = outcome(it, r)
        counts[(it["kind"], o)] += 1
        if args.only and o not in args.only.split(","):
            continue
        W, H = Image.open(os.path.join(run.CACHE, args.set, it["image"])).size
        k = r.get("scale", 1)
        looks = " ".join("%d%s%s%s" % (i, "H" if b["high"] else "N", "C" if b["colour"] else "", pct([c * k for c in b["box"]], W, H))
                         for i, b in enumerate(r.get("boxes", []), 1))
        target = ""
        if it.get("targets"):
            target = " | target %s, best view %s px" % (" ".join(pct(b, W, H) for b in it["targets"]),
                                                         "/".join("%g" % c[1] for c in run.covered(r.get("boxes", []), it["targets"], k)))
        truth = it.get("label") or "/".join(sorted(set(it.get("answers", []))))[:40]
        print("%-6s %-9s %s%s | looks %s | %s -> %s (truth %s, sure %s, %d B)" % (
            it["id"], o, it["question"][:60], target, looks or "none", r["answer"].replace("\n", " ")[:70],
            r.get("picked") or "%.2f" % r["score"], truth, r["sure"], r.get("bytes", 0)))
    print("\n%-18s %s" % ("", "  ".join("%9s" % o for o in OUTCOMES)))
    for kind in sorted({k for k, _ in counts}):
        print("%-18s %s" % (kind, "  ".join("%9d" % counts[(kind, o)] for o in OUTCOMES)))


if __name__ == "__main__":
    main()
