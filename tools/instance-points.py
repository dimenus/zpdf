# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools==4.67.0"]
# ///
"""Print fontTools' full instance of a variable font in the canonical form zpdf's tests hash.

    uv run tools/instance-points.py FONT --variations=wght=900,wdth=60 [--text] [--paths]

The instance is fontTools.varLib.instancer.instantiateVariableFont with every fvar axis pinned
(axes not named stay at their default), saved and read back, so the numbers are the ones a file
holds. Overlap flags are not set (OverlapMode.KEEP_AND_DONT_SET_FLAGS), because zpdf does not set
them. Prints the normalized coordinates fontTools used (F2Dot14, fvar order) and the SHA-256 of
the canonical text; --text prints the text instead.

The canonical text is one line per glyph id, every glyph of the font, each ending in "\\n":
  <gid> e <advance> <lsb>                                    an empty glyph
  <gid> s <advance> <lsb> <xMin> <yMin> <xMax> <yMax> | <end> ... | <x> <y> <flags> ...
                                                             a simple glyph; flags & 0xC1
  <gid> c <advance> <lsb> <xMin> <yMin> <xMax> <yMax> | <component> ; <component> ...
                                                             a composite glyph
A component is "<child gid> <flags> x <dx> <dy>" or, for one placed by point numbers,
"<child gid> <flags> a <parent point> <child point>", followed by " t <xx> <xy> <yx> <yy>" (F2Dot14
integers, in the order the file stores a 2x2 matrix) when it has a scale. Component flags are
masked to the bits that change the drawing (ARGS_ARE_XY_VALUES is the x or a): 0x0004, 0x0200, 0x0400, 0x0800, 0x1000.
zpdf's sfnt.zig builds the same text from its instanced subset (instanceDump); keep the two equal.

--paths prints (or hashes) every glyph's outline instead, one line per glyph id:
  <gid>[ M x y| L x y| Q cx cy x y| Z]...
Each glyph is flattened with getCoordinates (which places point-matched components, unlike a
decomposing pen) and drawn with fontTools' own glyf draw, into a pen that splits each string of
off-curve points into single quadratic curves (BasePen). A number is printed in the shortest
form that reads back to the same double, without an exponent, and -0 as 0. A font without fvar
is drawn as it is. zpdf's Outlines.path makes the same text (instancer.zig, pathsDump).
"""

import argparse
import hashlib
import io
import sys

from decimal import Decimal

from fontTools.misc.fixedTools import floatToFixed
from fontTools.pens.basePen import BasePen
from fontTools.ttLib.tables._g_l_y_f import Glyph
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

SIMPLE_FLAGS = 0xC1
COMPONENT_FLAGS = 0x0004 | 0x0200 | 0x0400 | 0x0800 | 0x1000


def parse_variations(text):
    out = {}
    for item in filter(None, text.split(",")):
        tag, value = item.split("=")
        out[tag.ljust(4)] = float(value)
    return out


def canonical(font):
    glyf = font["glyf"]
    hmtx = font["hmtx"]
    order = font.getGlyphOrder()
    gid_of = {name: i for i, name in enumerate(order)}
    lines = []
    for gid, name in enumerate(order):
        g = glyf[name]
        adv, lsb = hmtx[name]
        if g.numberOfContours == 0:
            lines.append(f"{gid} e {adv} {lsb}")
            continue
        head = f"{adv} {lsb} {g.xMin} {g.yMin} {g.xMax} {g.yMax}"
        if g.isComposite():
            comps = []
            for c in g.components:
                flags = c.flags & COMPONENT_FLAGS
                if hasattr(c, "firstPt"):
                    s = f"{gid_of[c.glyphName]} {flags} a {c.firstPt} {c.secondPt}"
                else:
                    s = f"{gid_of[c.glyphName]} {flags} x {c.x} {c.y}"
                if hasattr(c, "transform"):
                    (xx, xy), (yx, yy) = c.transform
                    s += " t " + " ".join(str(floatToFixed(v, 14)) for v in (xx, xy, yx, yy))
                comps.append(s)
            lines.append(f"{gid} c {head} | " + " ; ".join(comps))
        else:
            coords, ends, flags = g.getCoordinates(glyf)
            pts = " ".join(f"{int(x)} {int(y)} {f & SIMPLE_FLAGS}" for (x, y), f in zip(coords, flags))
            lines.append(f"{gid} s {head} | " + " ".join(map(str, ends)) + f" | {pts}")
    return "".join(line + "\n" for line in lines)


def num(v):
    v = v + 0.0
    return str(int(v)) if v == int(v) else format(Decimal(repr(v)), "f")


class PathText(BasePen):
    def __init__(self):
        super().__init__(None)
        self.out = []

    def _moveTo(self, p):
        self.out.append(f"M {num(p[0])} {num(p[1])}")

    def _lineTo(self, p):
        self.out.append(f"L {num(p[0])} {num(p[1])}")

    def _qCurveToOne(self, c, p):
        self.out.append(f"Q {num(c[0])} {num(c[1])} {num(p[0])} {num(p[1])}")

    def _curveToOne(self, c1, c2, p):
        raise ValueError("cubic contour")

    def _closePath(self):
        self.out.append("Z")


def paths(font):
    glyf = font["glyf"]
    lines = []
    for gid, name in enumerate(font.getGlyphOrder()):
        g = glyf[name]
        pen = PathText()
        if g.numberOfContours != 0:
            coords, ends, flags = g.getCoordinates(glyf)
            flat = Glyph()
            flat.numberOfContours = len(ends)
            flat.coordinates = coords
            flat.endPtsOfContours = ends
            flat.flags = flags
            flat.draw(pen, glyf)
        lines.append(" ".join([str(gid)] + pen.out))
    return "".join(line + "\n" for line in lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("font")
    ap.add_argument("--variations", default="")
    ap.add_argument("--text", action="store_true")
    ap.add_argument("--paths", action="store_true")
    args = ap.parse_args()

    font = TTFont(args.font)
    if "fvar" not in font:
        text = paths(font) if args.paths else canonical(font)
        if args.text:
            sys.stdout.write(text)
        else:
            print("sha256:", hashlib.sha256(text.encode()).hexdigest())
        return
    wanted = parse_variations(args.variations)
    limits = {}
    for axis in font["fvar"].axes:
        value = wanted.get(axis.axisTag, axis.defaultValue)
        limits[axis.axisTag] = min(max(value, axis.minValue), axis.maxValue)
    normalized = instancer.AxisLimits(limits).limitAxesAndPopulateDefaults(font).normalize(font)
    coords = [floatToFixed(normalized[a.axisTag].default, 14) for a in font["fvar"].axes]

    inst = instancer.instantiateVariableFont(
        font, limits, overlap=instancer.OverlapMode.KEEP_AND_DONT_SET_FLAGS
    )
    buf = io.BytesIO()
    inst.save(buf)
    buf.seek(0)
    text = (paths if args.paths else canonical)(TTFont(buf))
    if args.text:
        sys.stdout.write(text)
        return
    print("normalized:", ", ".join(map(str, coords)))
    print("sha256:", hashlib.sha256(text.encode()).hexdigest())


if __name__ == "__main__":
    main()
