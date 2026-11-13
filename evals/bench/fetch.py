"""Downloads the public benchmarks MuZip is measured on into cache/bench/<name>/ (git-ignored): only the questions
used and their photos, in one format (questions.jsonl, one question a line):

  {"id", "image": path under cache/bench/<name>/, "question", "kind",
   "options": [[letter, text], ...] and "label": a letter          (multiple choice), or
   "answers": the ten human answers                                (open, scored like VQA),
   "targets": [[x, y, w, h], ...] the objects that decide it, in photo pixels   (V* only)}

  vstar     V* Bench (craigwu/vstar_bench): all 191; small things in ~2,250 px photos; colour/material and left/right
  hrbench   HR-Bench 4K (DreamMr/HR-Bench): its 200 questions about 4K photos, one of each question's four option
            orders (picked by a hash, so the right letter varies); "single" (one detail) and "cross" (several)
  textvqa   TextVQA (validation): SAMPLE questions about reading text in photos (1,024 px), open answers

    .venv/bin/python evals/bench/fetch.py               # all three (HR-Bench needs pyarrow: pip install pyarrow)
    .venv/bin/python evals/bench/fetch.py textvqa
"""
import base64
import hashlib
import io
import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CACHE = os.path.join(ROOT, "cache", "bench")
HF = "https://huggingface.co/datasets/"
ROWS = "https://datasets-server.huggingface.co/rows?dataset=%s&config=%s&split=%s&offset=%d&length=%d"
SAMPLE = 200


def h(s):
    return hashlib.sha1(str(s).encode()).hexdigest()


def get(url, path=None, tries=6):
    for k in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "muzip-bench"}), timeout=120) as r:
                data = r.read()
            break
        except urllib.error.HTTPError as ex:
            if ex.code not in (429, 500, 502, 503, 504) or k == tries - 1:
                raise
            time.sleep(5 * 2 ** k)  # the rows API allows a few requests a second
    if path:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path + ".part", "wb") as f:
            f.write(data)
        os.replace(path + ".part", path)
    return data


def save(name, rows):
    with open(os.path.join(CACHE, name, "questions.jsonl"), "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    print("%s: %d questions in %s" % (name, len(rows), os.path.join(CACHE, name)))


def vstar():
    d = os.path.join(CACHE, "vstar")
    base = HF + "craigwu/vstar_bench/resolve/main/"
    lines = get(base + "test_questions.jsonl").decode().splitlines()
    src = [json.loads(line) for line in lines if line.strip()]

    def one(q):
        img = os.path.join(d, q["image"])
        if not os.path.exists(img):
            get(base + q["image"], img)
        meta_path = img[:-4] + ".json"
        if not os.path.exists(meta_path):
            get(base + q["image"][:-4] + ".json", meta_path)
        with open(meta_path) as f:
            meta = json.load(f)
        text = q["text"].split("\nAnswer with")[0]
        options = [[line[1], line[4:]] for line in text.split("\n")[1:] if line.startswith("(")]
        return {"id": q["question_id"], "image": q["image"], "question": text.split("\n")[0], "kind": q["category"],
                "options": options, "label": q["label"], "targets": meta["bbox"]}
    with ThreadPoolExecutor(16) as pool:
        save("vstar", list(pool.map(one, src)))


def hrbench():
    import pyarrow.parquet as pq
    d = os.path.join(CACHE, "hrbench")
    pq_path = os.path.join(d, "hr_bench_4k.parquet")
    if not os.path.exists(pq_path):
        get(HF + "DreamMr/HR-Bench/resolve/main/hr_bench_4k.parquet", pq_path)
    rows = pq.read_table(pq_path).to_pylist()
    by_q = {}
    for r in rows:  # four option orders of each question, in a row
        by_q.setdefault(r["index"] // 4, []).append(r)
    out = []
    for qn, cycles in sorted(by_q.items()):
        r = cycles[int(h("hrbench%d" % qn), 16) % len(cycles)]
        rel = "img/%d.jpg" % qn
        path = os.path.join(d, rel)
        if not os.path.exists(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(base64.b64decode(r["image"]))
        out.append({"id": str(qn), "image": rel, "question": r["question"], "kind": r["category"],
                    "options": [[k, r[k]] for k in "ABCD" if r.get(k)], "label": r["answer"]})
    save("hrbench", out)
    os.remove(pq_path)  # 430 MB; the questions used are kept


def textvqa():
    from PIL import Image
    d = os.path.join(CACHE, "textvqa")
    ds, total, page = "lmms-lab-encoder/textvqa", 5000, 100
    rows = []
    for off in range(0, total, page):
        rows += [r["row"] for r in json.loads(get(ROWS % (ds, "default", "validation", off, page)))["rows"]]
    rows = sorted(rows, key=lambda r: h("textvqa%s" % r["question_id"]))[:SAMPLE]

    def one(r):
        rel = "img/%s.jpg" % r["image_id"]
        path = os.path.join(d, rel)
        if not os.path.exists(path):
            Image.open(io.BytesIO(get(r["image"]["src"]))).convert("RGB").save(path, quality=95)
        return {"id": str(r["question_id"]), "image": rel, "question": r["question"], "kind": "text", "answers": r["answers"]}
    os.makedirs(os.path.join(d, "img"), exist_ok=True)
    with ThreadPoolExecutor(4) as pool:
        save("textvqa", list(pool.map(one, rows)))


SETS = {"vstar": vstar, "hrbench": hrbench, "textvqa": textvqa}

if __name__ == "__main__":
    for name in sys.argv[1:] or SETS:
        os.makedirs(os.path.join(CACHE, name), exist_ok=True)
        SETS[name]()
