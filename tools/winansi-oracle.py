# /// script
# requires-python = ">=3.11"
# ///
"""Write tests/winansi/table.tsv: every code point zpdf's standard fonts can draw, and its WinAnsi byte.

    uv run tools/winansi-oracle.py tests/winansi/table.tsv

The oracle is Python's cp1252 codec (PDF's WinAnsiEncoding is code page 1252's characters, ISO
32000-1 Annex D), minus C0 controls and DEL: cp1252 maps those to themselves, but the standard fonts
have no glyph for them. One line per code point: <code point, hex>\t<byte, hex>.
"""

import sys

with open(sys.argv[1], "w") as out:
    for cp in range(0x110000):
        if cp < 0x20 or cp == 0x7F:
            continue
        try:
            b = chr(cp).encode("cp1252")
        except (UnicodeEncodeError, ValueError):
            continue
        out.write(f"{cp:04X}\t{b[0]:02X}\n")
