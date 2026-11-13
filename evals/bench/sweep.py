"""The accuracy-vs-bytes trade-off: MuZip at several amounts of detail, against WebP at fixed sizes, with the photo
sent whole (what Muse gets from everything) as the ceiling. Each MuZip setting is one point: its mean and median
bytes per question and its share right; each WebP size is another. Runs evals/bench/run.py once per setting (its
results are kept, so a re-run only does what's missing), then prints the table and writes out/eval/bench/sweep.json.

MuZip settings ("detail"): how many close-ups and texts it may use (closer.MAX_VIEWS, closer.BUDGET), and how big each
picture is (smsimage.SIDE: the sketch and a normal close-up; codes.HIGH: a high-detail close-up).

    .venv/bin/python evals/bench/sweep.py                    # every setting, all three dev splits
    .venv/bin/python evals/bench/sweep.py --only s128-v8-b160 --sets vstar
    .venv/bin/python evals/bench/sweep.py --report           # the table from what's there, no runs
"""
import argparse
import json
import os
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run  # noqa: E402

# name: (side, high, max views, budget in texts). s128-v8-b160 is the loop as it ships.
MUZIP = {  # in the order they run: the most telling first
    "s128-v8-b160": (128, 256, 8, 160),
    "s256-v8-b640": (256, 512, 8, 640),
    "s192-v8-b360": (192, 384, 8, 360),
    "s96-v8-b100": (96, 192, 8, 100),
    "s128-v2-b40": (128, 256, 2, 40),
    "s128-v4-b80": (128, 256, 4, 80),
    "s256-v16-b1600": (256, 512, 16, 1600),
    "s128-v16-b480": (128, 256, 16, 480),
    "s128-v32-b1600": (128, 256, 32, 1600),
}
WEBP = [1000, 2000, 4000, 8000, 16000, 32000, 64000, 128000]
SETS = ["vstar", "hrbench", "textvqa"]


def tag(setting):
    side, high, views, budget = MUZIP[setting]
    return run.tag_for(side, high, views, budget)


def results(name, way, t, items):
    d = os.path.join(run.OUT, name, way, t)
    out = []
    for it in items:
        p = os.path.join(d, it["id"] + ".json")
        if os.path.exists(p):
            with open(p) as f:
                out.append(json.load(f))
    return out


def point(rows, n):
    if len(rows) < n:
        return None
    b = [r.get("bytes", 0) for r in rows]
    return {"right": round(100 * sum(r["score"] for r in rows) / n, 1), "mean_bytes": round(statistics.mean(b)),
            "median_bytes": round(statistics.median(b)), "n": n,
            "right_when_sure": round(100 * sum(r["score"] for r in rows if r["sure"] == "yes") / max(1, sum(r["sure"] == "yes" for r in rows)), 1)}


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--sets", default=",".join(SETS))
    a.add_argument("--only", help="comma-separated MuZip settings")
    a.add_argument("--split", default="dev")
    a.add_argument("--report", action="store_true", help="only print what has been run")
    a.add_argument("--workers", default="24")
    args = a.parse_args()
    sets = args.sets.split(",")
    settings = args.only.split(",") if args.only else list(MUZIP)
    py = sys.executable
    if not args.report:
        ways = "full," + ",".join("webp@%d" % b for b in WEBP)
        subprocess.run([py, os.path.join(HERE, "run.py"), "--set", ",".join(sets), "--split", args.split, "--ways", ways, "--workers", args.workers])
        for s in settings:
            side, high, views, budget = MUZIP[s]
            print("== %s" % s, flush=True)
            subprocess.run([py, os.path.join(HERE, "run.py"), "--set", ",".join(sets), "--split", args.split, "--ways", "muzip",
                            "--side", str(side), "--high", str(high), "--max-views", str(views), "--budget", str(budget),
                            "--workers", args.workers])
    table = {}
    for name in sets:
        items = [it for it in run.load(name) if args.split == "all" or it["split"] == args.split]
        n = len(items)
        table[name] = {"full": point(results(name, "full", "v1", items), n),
                       "webp": {b: point(results(name, "webp@%d" % b, "v1", items), n) for b in WEBP},
                       "muzip": {s: point(results(name, "muzip", tag(s), items), n) for s in MUZIP}}
        print("\n%s (%s, %d questions)" % (name, args.split, n))
        print("  %-16s %7s %11s %13s %10s" % ("", "right", "mean bytes", "median bytes", "sure: right"))
        rows = [("full photo", table[name]["full"])] + [("webp %d" % b, p) for b, p in table[name]["webp"].items()] + \
               [("muzip " + s, p) for s, p in table[name]["muzip"].items()]
        for label, p in rows:
            if p:
                print("  %-20s %5.1f%% %11d %13d %9.0f%%" % (label, p["right"], p["mean_bytes"], p["median_bytes"], p["right_when_sure"]))
    with open(os.path.join(run.OUT, "sweep.json"), "w") as f:
        json.dump(table, f, indent=1)


if __name__ == "__main__":
    main()
