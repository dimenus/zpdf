# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools==4.60.1"]
# ///
"""Writes tests/read/cff/: bare CFF font programs (as a PDF embeds one in /FontFile3 /Type1C) and,
for each, the glyph name of each code of its built-in encoding as fontTools reads it back from
the written bytes. src/cff.zig's test reads each program and must give the same names.

    uv run tools/cff-fixtures.py        (from the repo root)

Each program is built with fontTools' FontBuilder and written by its CFF compiler, which picks a
charset and encoding format by itself; the tool checks that the programs together cover every
format src/cff.zig reads (charset ISOAdobe, 0, 1, 2; encoding Standard, 0, 1), and stops if not.
Encoding supplements are not written by fontTools; src/cff.zig's test builds one by hand.

The expected names come from fontTools reading the file (cffLib), not from what was asked for:
a Standard-encoded program names a code only when it has a glyph by StandardEncoding's name.
"""

import io
import json
from pathlib import Path

from fontTools.cffLib import CFFFontSet, cffISOAdobeStrings
from fontTools.encodings.StandardEncoding import StandardEncoding
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.t2CharStringPen import T2CharStringPen

OUT = Path("tests/read/cff")


def program(names, encoding):
    """A bare CFF with glyphs `names` (.notdef first) and `encoding` (None: Standard; else a list of
    256 glyph names, ".notdef" for an unused code)."""
    fb = FontBuilder(1000, isTTF=False)
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap({})
    pen = T2CharStringPen(500, None)
    pen.moveTo((0, 0))
    pen.lineTo((100, 0))
    pen.lineTo((100, 100))
    pen.closePath()
    cs = pen.getCharString()
    fb.setupCFF("ZpdfTest", {"FullName": "ZpdfTest"}, {n: cs for n in names}, {})
    fb.setupHorizontalMetrics({n: (500, 0) for n in names})
    fb.setupHorizontalHeader()
    fb.setupPost()
    cff = fb.font["CFF "].cff
    top = cff[cff.fontNames[0]]
    if encoding is not None:
        top.Encoding = encoding
    out = io.BytesIO()
    cff.compile(out, fb.font)
    return out.getvalue()


def read_back(data):
    """code -> glyph name, by fontTools reading `data`; and the charset and encoding formats."""
    cff = CFFFontSet()
    cff.decompile(io.BytesIO(data), None)
    top = cff[cff.fontNames[0]]
    charset = list(top.charset)
    enc = top.Encoding
    if enc == "StandardEncoding" or enc is None:
        present = set(charset)
        names = {c: n for c, n in enumerate(StandardEncoding) if n != ".notdef" and n in present}
        enc_format = "Standard"
    else:
        names = {c: n for c, n in enumerate(enc) if n != ".notdef"}
        at = top.rawDict["Encoding"]
        enc_format = data[at] & 0x7F
    charset_at = top.rawDict.get("charset", 0)
    charset_format = "ISOAdobe" if charset_at == 0 else data[charset_at]
    return names, charset_format, enc_format


def custom(pairs):
    enc = [".notdef"] * 256
    for code, name in pairs:
        enc[code] = name
    return enc


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    iso = list(cffISOAdobeStrings[:60])
    letters = [n for n in cffISOAdobeStrings if len(n) == 1 and n.isalpha()]
    many = [".notdef"] + [f"g{i:03}" for i in range(300)]  # custom names, past 255 in a range
    cases = {
        # The ISOAdobe charset (its first 60 names, in order) and Standard encoding.
        "isoadobe-standard": (iso, None),
        # A subset, out of SID order: a charset of single SIDs (format 0); Standard names only the
        # codes whose glyph is there.
        "subset-standard": ([".notdef", "Z", "a", "quotedbl", "eight", "A"], None),
        # Scattered codes: encoding format 0; names from the font's String INDEX.
        "custom-scattered": ([".notdef", "A", "alpha.sc", "B", "x.alt"], custom([(3, "A"), (200, "alpha.sc"), (65, "B"), (255, "x.alt")])),
        # Runs of codes and of SIDs: encoding format 1, charset format 1.
        "custom-runs": ([".notdef"] + letters[:20], custom([(32 + i, n) for i, n in enumerate(letters[:10])] + [(97 + i, n) for i, n in enumerate(letters[10:20])])),
        # 300 glyphs with consecutive new SIDs: charset format 2 (a range past 255).
        "custom-long-charset": (many, custom([(c, many[c]) for c in range(1, 200)])),
    }
    formats = {"charset": set(), "encoding": set()}
    for name, (glyphs, enc) in cases.items():
        data = program(glyphs, enc)
        names, charset_format, enc_format = read_back(data)
        formats["charset"].add(charset_format)
        formats["encoding"].add(enc_format)
        (OUT / f"{name}.cff").write_bytes(data)
        (OUT / f"{name}.json").write_text(json.dumps({str(c): n for c, n in sorted(names.items())}, indent=0) + "\n")
        print(f"{name}: {len(data)} bytes, charset {charset_format}, encoding {enc_format}, {len(names)} codes")
    want = {"charset": {"ISOAdobe", 0, 1, 2}, "encoding": {"Standard", 0, 1}}
    for k in want:
        if not want[k] <= formats[k]:
            raise SystemExit(f"the fixtures do not cover {k} formats {want[k] - formats[k]}")


if __name__ == "__main__":
    main()
