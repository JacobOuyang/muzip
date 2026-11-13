"""MuZipCore (the Mac and iPhone app's codes and pictures, app/MuZip) against the Python phone: the server must read
what the app sends exactly as it reads what evac/codes.py makes. Runs app/MuZip's muzip-cli; skipped when it isn't
built (cd app/MuZip && swift build --product muzip-cli)."""
import io
import os
import subprocess
import sys
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, ROOT)
from PIL import Image, ImageOps  # noqa: E402

from evac import codes, smsimage  # noqa: E402

CLI = os.path.join(ROOT, "app", "MuZip", ".build", "debug", "muzip-cli")
PHOTO = os.path.join(ROOT, "sim", "samples", "hard", "extinguisher.jpg")


def cli(*args):
    return subprocess.run([CLI, *args], capture_output=True, text=True, check=True).stdout.strip().split("\n")


@unittest.skipUnless(os.path.exists(CLI), "muzip-cli not built")
class SwiftCoreTest(unittest.TestCase):
    def setUp(self):
        self.img = ImageOps.exif_transpose(Image.open(PHOTO)).convert("RGB")

    def test_the_sketch_decodes_as_the_python_sketch_would(self):
        out = cli("sketch", PHOTO, "ab")
        parts, size = out[:-1], out[-1].split()[1:]
        self.assertTrue(all(len(p) <= codes.PART_CHARS for p in parts))
        found = codes.decode("\n".join(parts))
        self.assertEqual(found["missing"], {})
        pic = Image.open(io.BytesIO(found["complete"][0]["data"]))
        self.assertEqual(pic.size, smsimage.fit(self.img).size)
        self.assertEqual([int(v) for v in size], list(pic.size))
        python = len(smsimage.webp(self.img))
        self.assertLess(abs(len(found["complete"][0]["data"]) - python), python * 0.5)  # about the same size

    def test_a_close_up_matches_the_python_crop(self):
        for line in ("ZOOM ab 81 47 26 32 C", "ZOOM ab 93 53 10 8 C H", "ZOOM ab 10 10 60 40", "ZOOM ab 0 0 3 3 H"):
            out = cli("zoom", PHOTO, "ab", line)
            parts = out[:-2]
            data = codes.decode("\n".join(parts))["complete"][0]["data"]
            parent, box, webp = codes.read_zoom(data)
            m = codes.zooms(line, "ab")[0]
            want_data, _, want_box, want_size = codes.crop_zoom(self.img, (0, 0, self.img.width, self.img.height),
                                                                 smsimage.fit(self.img).size, [int(x) for x in m.group(2).split()],
                                                                 **codes.zoom_options(m))
            self.assertEqual(parent, "ab")
            for a, b in zip(box, want_box):
                self.assertAlmostEqual(a, b, delta=1 / 32, msg=line)
            got = Image.open(io.BytesIO(webp))
            self.assertEqual(list(got.size), want_size, line)
            self.assertEqual(got.mode == "RGB" and "C" in line or "C" not in line, True)


if __name__ == "__main__":
    unittest.main()
