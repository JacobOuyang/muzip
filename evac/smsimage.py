"""Tiny pictures for plain text messages, which evac/codes.py sends as #P and #Z codes:
a 1-bit PNG (line drawings; a step picture is 300-500 bytes, 3-5 SMS) or a greyscale WebP (photos and zooms). Both fit in 128 px with their aspect kept."""
import io

from PIL import Image, ImageOps

SIDE = 128  # the sketch and a normal close-up fit in this many pixels (read at call time, so evals can vary it)


def fit(img, side=None):
    """Greyscale, shrunk to fit in side x side (aspect kept)."""
    side = side or SIDE
    g = img.convert("L")
    g.thumbnail((side, side), Image.LANCZOS)
    return g


def png(img, side=None):
    """The picture as a 1-bit PNG fitting in `side` pixels (black ink on white): outlines and line drawings."""
    s = fit(img, side).point(lambda v: 255 if v > 140 else 0).convert("1")
    buf = io.BytesIO()
    s.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def webp(img, side=None, quality=5, colour=False):
    """The picture as a small greyscale WebP (contrast stretched first): photos and zooms. On the six sample photos
    quality 5 took 284-1386 bytes, about what a 1-bit PNG takes, but a busy or dark photo stays readable where the
    1-bit one turns to noise (the bicycle against a brick wall) or vanishes (a white sneaker). Browsers decode it.
    colour=True keeps colour, for a close-up where colour decides the answer (a red mark on a spider): at quality 5
    colour smears into blocks, so it gets quality 30."""
    side = side or SIDE
    buf = io.BytesIO()
    if colour:
        small = img.convert("RGB")
        small.thumbnail((side, side), Image.LANCZOS)
        small.save(buf, "WEBP", quality=max(quality, 30), method=6)
    else:
        ImageOps.autocontrast(fit(img, side), cutoff=1).save(buf, "WEBP", quality=quality, method=6)
    return buf.getvalue()
