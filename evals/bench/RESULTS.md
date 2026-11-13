# MuZip on V* Bench: accuracy against bytes

V* Bench (`craigwu/vstar_bench`) has 191 multiple-choice questions about small things in large photos (median
2,250 px; the target is a median 3.7 px across in MuZip's 128 px sketch). There are two kinds: `direct_attributes`
(colour or material, four options) and `relative_position` (left or right, two options). It is split in half by a
hash of the question id: dev (96, tuned on, reported here) and test (95, not run yet). Answers are scored by option
letter, with no judge. A "can't tell" counts as wrong.

```bash
.venv/bin/python evals/bench/fetch.py vstar                         # 269 MB into cache/bench/vstar/
.venv/bin/python evals/bench/sweep.py --sets vstar                  # every setting below (results are kept)
.venv/bin/python evals/bench/sweep.py --sets vstar --report         # the table, no runs
.venv/bin/python evals/bench/steps.py --set vstar --tag <loop tag>  # where each close-up went, per question
```

Per question, only the answer, the bytes, and each close-up's box, colour, detail and size are kept
(`out/eval/bench/vstar/<way>/<tag>/<id>.json`). The photos are not copied, since the box and the original rebuild
any close-up.

## What the best methods score (none count bytes)

Every method below sees the whole photo at full resolution.

| Method | V* | How |
| --- | --- | --- |
| o3 | 95.7 | thinks with images (crops and zooms in its reasoning) |
| BVS (Qwen3-VL-8B) | 93.2 | visual search trained with RL |
| TreeVGR | 91.1 | grounded reasoning, boxes traced in the answer |
| ZoomEye | 90.6 | tree search over zoomed views, no training |
| DeepEyes | 90.1 | RL-trained zoom-in tool calls (83.3 averaged over 32 runs) |
| Mini-o3 | 88.2 | multi-turn image tool use |
| Chain-of-Focus | 88.0 | adaptive zoom, trained |
| SEAL | 75.4 | the benchmark's own guided search |
| Qwen2.5-VL-7B | 71–75 | one look |
| GPT-4o | 65–66 | one look |
| **Muse Spark, the photo sent whole** | **91.7** (dev) | one look, a JPEG of at most 2,048 px, ~850 KB |

Muse Spark with the whole photo is already near the top. The question for MuZip is how close it gets to that 91.7%,
and with how few bytes.

## The trade-off (dev, 96 questions)

**MuZip settings.** Each setting is one point:
- `s` is the sketch's side and a normal close-up's side; a high-detail close-up is twice that.
- `v` is the most close-ups allowed.
- `b` is the budget in texts.

The shipped loop is `s128-v8-b160`. **WebP** is the whole photo squeezed to a fixed size, at the widest side that
keeps quality ≥ 20.

| | right | mean bytes | median bytes | right when sure | target seen | right when seen / not seen |
| --- | --- | --- | --- | --- | --- | --- |
| photo sent whole | **91.7%** | 848,614 | 838,418 | 97% | | |
| WebP 1 KB | 31.2% | 868 | 873 | | | |
| WebP 4 KB | 26.0% | 3,592 | 3,617 | | | |
| WebP 8 KB | 27.1% | 7,226 | 7,235 | | | |
| WebP 16 KB | 33.3% | 14,188 | 14,279 | | | |
| WebP 32 KB | 51.0% | 28,791 | 29,168 | | | |
| WebP 64 KB | 68.8% | 56,799 | 57,383 | | | |
| WebP 128 KB | 82.3% | 113,890 | 114,733 | | | |
| MuZip s128-v2-b40 | 17.7% | 3,750 | 3,634 | 90% | 15/96 | 73% / 7% |
| MuZip s128-v4-b80 | 26.0% | 6,476 | 5,971 | 88% | 18/96 | 78% / 14% |
| MuZip s96-v8-b100 | 35.4% | 7,074 | 6,575 | 85% | 23/96 | 74% / 23% |
| **MuZip s128-v8-b160 (shipped)** | 41.7% | 10,482 | 9,269 | 95% | 35/96 | 80% / 20% |
| MuZip s128-v16-b480 | 47.9% | 14,783 | 11,117 | 82% | 44/96 | 84% / 17% |
| MuZip s128-v32-b1600 | 53.1% | 13,619 | 8,623 | 89% | 40/96 | 95% / 23% |
| MuZip s192-v8-b360 | 59.4% | 18,138 | 13,708 | 93% | 59/96 | 81% / 24% |
| MuZip s256-v8-b640 | 63.5% | 23,450 | 17,434 | 92% | 62/96 | 89% / 18% |
| **MuZip s256-v16-b1600** | **71.9%** | 33,419 | 21,848 | 96% | 69/96 | 87% / 33% |

"Target seen" means some close-up showed the benchmark's target object at least 16 px across.

**What it shows**

- **MuZip beats WebP at every size it was run at**, and the gap is largest where the bytes are fewest:
  - At about 10 KB, MuZip is right 42% of the time and WebP 27–33%.
  - At about 30 KB, MuZip (256 px, 16 close-ups) is right 72% and WebP 51%.
  - WebP needs about 57 KB to reach 69%, and 114 KB for 82%.
  - So at the same accuracy, MuZip uses about half the bytes, or less.
- **No setting reaches the whole photo yet.** The best is 20 points short (72% against 92%) at 1/25 of the bytes.
  Nothing here suggests MuZip can beat the whole photo on V\*. Muse already reads the full JPEG well, so the ceiling
  is what MuZip should match, not beat.
- **The size of each close-up matters most; their number matters little.**
  - Going from 128 px to 256 px (same 8 close-ups) took it from 42% to 64%.
  - Going from 8 to 32 close-ups at 128 px took it from 42% to 53%.
  - Muse stops early either way: the median is 4–7 close-ups whatever the limit.
- **Failures are search failures.** When a close-up showed the target sharp (≥ 16 px), MuZip was right 80–95% of
  the time at every setting. When none did, it was right 7–33%.
  - Bigger close-ups raise how often the target is seen: 35/96 at 128 px, 62/96 at 256 px, 69/96 with 16 at 256 px.
  - Each look covers four times the pixels, so the third-of-the-photo tiles Muse asks for already resolve a
    4 px-in-the-sketch target.
- **Left-or-right questions are the weak kind.** At most 22/38 are right, below the 50% a guess would get, because
  "can't tell" counts as wrong. The colour questions reach 47/58.
- **When Muse says it is sure, it is right 82–96% of the time**, at every setting. The extra misses come from it
  abstaining, not from confident misreads.
- **The runs are noisy.** The shipped setting scored 48% on the first run and 41.7% on this one, with prompts
  identical at the defaults. Treat differences under about 6 points (6 questions) as noise.

## Easy wins tried, then reverted

Both ran on dev at the shipped setting, before the sweep:

1. **Search at high detail first** (tell Muse to use H for the first sweep of a small object): 39%, worse than the
   48% it started from. It spent the budget on fewer, bigger close-ups and saw less of the photo.
2. **SAM hints** (run SAM 3.1 on the sketch for the named object and show its guesses): 50%, no change. On a 128 px
   sketch the targets are too small for SAM to find; `evals/closer/RESULTS.md` found the same.

The only change kept is plumbing, so the sweep can vary the sizes:
- `smsimage.SIDE` is now read when called.
- The prompt uses `{side}`/`{high}`.
- The cost per look scales with the side.

At the defaults the prompt is unchanged. `evals/loop/run.py` gave 27/36 right on the changed loop and 25/36 on the
unchanged one (baseline 29/36), which is within noise on the same questions.

## What to change next

1. **Make 256 px the normal close-up for search** (512 px for high detail), and keep the 128 px sketch as the first
   view.
   - The sketch matters little: Muse can't see the target in it at any size, and it only decides where to look.
   - This is the setting that moved the most: 64% at a median 17 KB, against 42% at 9 KB.
2. **Budget in bytes, not texts or close-ups.**
   - Give Muse a byte budget and let it choose each close-up's side (128/256/512) and colour, and let it spend
     less on easy questions.
   - Report the curve: right against mean bytes.
3. **Stop answering "can't tell" on two-option questions** when the target was seen. Look first at the left/right
   misses with `steps.py` to tell search misses from abstentions.
4. Run **test** only once these settle, at two or three points on the curve.
