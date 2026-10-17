# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools==4.67.0", "pillow", "numpy"]
# ///
"""Render glyphs of a variable font at an instance with zpdf (zpdf-text, then mutool) and with
HarfBuzz (hb-view), and measure how far apart the two pictures are.

    uv run tools/render-compare.py --exe zig-out/bin/zpdf-text FONT VARIATIONS CHARS [...]

Arguments after --exe come in threes: a font file, HarfBuzz-style variations ("wght=900,wdth=80"),
and the characters to draw. Each character is drawn alone by zpdf (one that shapes to more than one
glyph is skipped and listed), and HarfBuzz draws the glyph id
zpdf drew (read from the PDF's CIDToGIDMap, hb-view --glyphs), so only outlines are compared:
shaping is tested elsewhere, and kb's known shaping differences cannot change the glyph here.

The measure. Every render is at 600 pixels per em (zpdf: 72 pt at 600 dpi; hb-view: font size
600), grey, white background. Ink is 1 - grey/255. Each picture is cut to the box of its ink
(ink > 0.1) and the two are laid on one canvas at their top-left corners; then the second picture
is moved (bilinear) by every offset from -1 to +1 pixel in steps of 1/4, in x and y, because
cutting at whole pixels leaves two renders of one outline up to a pixel apart. The score is the
smallest of
    D = sum |ink_a - ink_b| / sum max(ink_a, ink_b)
over those offsets: 0 is the same picture, 1 shares no ink.

D is not 0 for one outline drawn by two rasterizers (MuPDF and Cairo spread an edge differently),
and the same edge error is a larger part of a thin glyph's ink than of a bold one's. HarfBuzz also
keeps instanced points unrounded, while a static font (fontTools' instance, zpdf's subset) must
round each to a whole font unit. So each glyph gets five scores:
  result     zpdf's PDF in mutool  vs  hb-view of the variable font at the instance
  noise      zpdf's PDF in mutool  vs  hb-view of the font zpdf embedded (the same outline, so
             this is the rasterizer difference for this glyph at this weight)
  fonttools  hb-view of the font zpdf embedded  vs  hb-view of fontTools' instance
             (instantiateVariableFont): one rasterizer, so any outline difference shows
  rounding   hb-view of fontTools' instance  vs  hb-view of the variable font at the instance:
             what rounding to whole units costs against HarfBuzz's unrounded points
  wrong      zpdf's PDF in mutool  vs  hb-view of the variable font at its default instance (what
             a PDF without instancing would be judged against)
A glyph passes when result <= 1.25 * noise + 0.002 + rounding, fonttools <= 0.0005 (the same
picture), and, when the instance changes the glyph (wrong > 0.05), wrong > 4 * result. Exit 1 if
any glyph fails.
"""

import argparse
import io
import os
import subprocess
import sys
import tempfile

import numpy as np
from fontTools.ttLib import TTFont
from PIL import Image

PPEM = 600


def ink(png_bytes):
    a = np.asarray(Image.open(io.BytesIO(png_bytes)).convert("L"), dtype=np.float64)
    return 1.0 - a / 255.0


def crop(a):
    ys, xs = np.nonzero(a > 0.1)
    if len(xs) == 0:
        return np.zeros((1, 1))
    return a[ys.min() : ys.max() + 1, xs.min() : xs.max() + 1]


def shifted(a, dx, dy):
    """`a` moved by (dx, dy) pixels, bilinear, on the same canvas."""
    ix, iy = int(np.floor(dx)), int(np.floor(dy))
    fx, fy = dx - ix, dy - iy
    out = np.zeros_like(a)
    for wy, oy in ((1 - fy, iy), (fy, iy + 1)):
        for wx, ox in ((1 - fx, ix), (fx, ix + 1)):
            if wx * wy == 0:
                continue
            moved = np.roll(np.roll(a, oy, axis=0), ox, axis=1)
            out += wx * wy * moved
    return out


def score(a, b):
    a = crop(a)
    b = crop(b)
    h = max(a.shape[0], b.shape[0]) + 4
    w = max(a.shape[1], b.shape[1]) + 4
    ca = np.zeros((h, w))
    ca[2 : 2 + a.shape[0], 2 : 2 + a.shape[1]] = a
    cb0 = np.zeros((h, w))
    cb0[2 : 2 + b.shape[0], 2 : 2 + b.shape[1]] = b
    best = 1.0
    steps = [i / 4 for i in range(-4, 5)]
    for dy in steps:
        for dx in steps:
            cb = shifted(cb0, dx, dy)
            den = np.maximum(ca, cb).sum()
            if den == 0:
                return 0.0
            best = min(best, np.abs(ca - cb).sum() / den)
    return best


def zpdf_render(exe, font, variations, ch, tmp):
    """zpdf's render of `ch`, the glyph id it drew, and the font it embedded."""
    pdf = os.path.join(tmp, "g.pdf")
    args = [exe, font, "--size=72", f"--out={pdf}", f"--unicodes=U+{ord(ch):04X}"]
    if variations:
        args.append(f"--variation={variations}")
    subprocess.run(args, check=True, capture_output=True)
    png = subprocess.run(["mutool", "draw", "-q", "-r", "600", "-c", "gray", "-F", "png", "-o", "-", pdf], check=True, capture_output=True).stdout
    # One font: objects 5..10 are Type0, CIDFontType2, FontDescriptor, FontFile2, CIDToGIDMap,
    # ToUnicode (pdf.zig). CID 1 is the one glyph drawn.
    cid_map = subprocess.run(["mutool", "show", "-b", pdf, "9"], check=True, capture_output=True).stdout
    if len(cid_map) != 4:
        return None, len(cid_map) // 2 - 1, None
    gid = int.from_bytes(cid_map[2:4], "big")
    embedded = os.path.join(tmp, "embedded.ttf")
    with open(embedded, "wb") as f:
        f.write(subprocess.run(["mutool", "show", "-b", pdf, "8"], check=True, capture_output=True).stdout)
    return ink(png), gid, embedded


def fonttools_instance(font, variations, tmp):
    from fontTools.varLib import instancer

    f = TTFont(font)
    wanted = {}
    for item in filter(None, variations.split(",")):
        tag, value = item.split("=")
        wanted[tag.ljust(4)] = float(value)
    limits = {}
    for axis in f["fvar"].axes:
        value = wanted.get(axis.axisTag, axis.defaultValue)
        limits[axis.axisTag] = min(max(value, axis.minValue), axis.maxValue)
    inst = instancer.instantiateVariableFont(f, limits, overlap=instancer.OverlapMode.KEEP_AND_DONT_SET_FLAGS)
    path = os.path.join(tmp, "fonttools.ttf")
    inst.save(path)
    return path


def hb_render(font, variations, gid):
    args = ["hb-view", "--glyphs", f"--font-size={PPEM}", "--margin=8", "-O", "png", "-o", "-", font, f"gid{gid}"]
    if variations:
        args.append(f"--variations={variations}")
    return ink(subprocess.run(args, check=True, capture_output=True).stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True)
    ap.add_argument("cases", nargs="+")
    args = ap.parse_args()
    if len(args.cases) % 3:
        sys.exit("cases come in threes: FONT VARIATIONS CHARS")
    failed = 0
    n = 0
    print("font\tvariations\tchar\tgid\tresult\tnoise\tfonttools\trounding\twrong\tverdict")
    with tempfile.TemporaryDirectory() as tmp:
        for i in range(0, len(args.cases), 3):
            font, variations, chars = args.cases[i : i + 3]
            cmap = TTFont(font)["cmap"].getBestCmap()
            ft_font = fonttools_instance(font, variations, tmp)
            for ch in chars:
                if ord(ch) not in cmap:
                    continue
                z, gid, embedded = zpdf_render(args.exe, font, variations, ch, tmp)
                if z is None:
                    print(f"{os.path.basename(font)}\t{variations}\t{ch}\tskipped: shaped to {gid} glyphs")
                    continue
                h_inst = hb_render(font, variations, gid)
                h_embedded = hb_render(embedded, "", gid)
                h_def = hb_render(font, "", gid)
                h_ft = hb_render(ft_font, "", gid)
                result = score(z, h_inst)
                noise = score(z, h_embedded)
                fonttools = score(h_embedded, h_ft)
                rounding = score(h_ft, h_inst)
                wrong = score(z, h_def)
                ok = result <= 1.25 * noise + 0.002 + rounding and fonttools <= 0.0005 and (wrong <= 0.05 or wrong > 4 * result)
                failed += not ok
                n += 1
                name = os.path.basename(font)
                print(f"{name}\t{variations}\t{ch}\t{gid}\t{result:.4f}\t{noise:.4f}\t{fonttools:.4f}\t{rounding:.4f}\t{wrong:.4f}\t{'ok' if ok else 'FAIL'}")
    print(f"glyphs {n}, failed {failed}")
    if n == 0:
        sys.exit(2)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
