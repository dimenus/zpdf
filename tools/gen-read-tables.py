# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools==4.60.1"]
# ///
"""Writes src/read_tables.zig: the font data zpdf.read needs to turn simple-font codes into text
and positions when a PDF does not carry them itself.

    uv run tools/gen-read-tables.py <afm-dir> src/read_tables.zig

<afm-dir> holds Adobe's Core 14 AFM files and MustRead.html, the Adobe Glyph List and the ITC Zapf
Dingbats Glyph List:
    https://raw.githubusercontent.com/apache/pdfbox/trunk/pdfbox/src/main/resources/org/apache/pdfbox/resources/afm/<name>
        (the 14 <Font>.afm files and MustRead.html)
    https://raw.githubusercontent.com/adobe-type-tools/agl-aglfn/master/glyphlist.txt
    https://raw.githubusercontent.com/adobe-type-tools/agl-aglfn/master/zapfdingbats.txt
and, to check TEX_NAMES against, the AMSFonts Type 1 fonts (OFL) and TeX's glyph list:
    https://mirrors.ctan.org/fonts/amsfonts.zip (its pfb/*.pfb, in <afm-dir>/amsfonts)
    https://raw.githubusercontent.com/kohler/lcdf-typetools/v2.110/texglyphlist.txt
They are inputs only; the AFM files are not checked in. Adobe's MustRead.html terms require the
copyright notices kept and modifications noted: the generated file repeats both.

What it writes:
- glyph_names: every Adobe Glyph List name that maps to ONE code point, and TEX_NAMES (none of
  them in the AGL), sorted by name.
- zapf_dingbats_names: the ITC Zapf Dingbats Glyph List (a1 to a191 and the others), sorted by
  name; the AGL Specification maps a ZapfDingbats font's glyph names by it before the AGL.
- standard_encoding, mac_roman_encoding: glyph name per code (ISO 32000-1 Annex D). Standard is
  read from Helvetica.afm's codes (its EncodingScheme is AdobeStandardEncoding); MacRoman comes
  from fontTools, which is Mac OS Roman with the old 0xDB "currency": PDF's MacRomanEncoding
  lacks 15 of its glyphs (the math and Greek ones, and the Apple logo), which a PDF font using
  this encoding would not use.
- cff_standard_strings: the 391 strings a CFF font program names glyphs by without storing
  them (Adobe Technical Note 5176, Appendix A), from fontTools' cffLib.
- For the 12 text fonts, the advance width (1/1000 em) of each glyph by code point, and the AFM's
  Ascender and Descender; for Symbol and ZapfDingbats, widths by code in their built-in encoding.
"""

import html
import pathlib
import re
import sys
import unicodedata

from fontTools import t1Lib
from fontTools.cffLib import cffStandardStrings
from fontTools.encodings.MacRoman import MacRoman

TEXT_FONTS = [
    "Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique",
    "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic",
    "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique",
]
SYMBOLIC = ["Symbol", "ZapfDingbats"]

# The glyph names of TeX's fonts that the AGL lacks, by Unicode character name: Computer Modern
# (cmr and its text fonts, cmmi, cmsy, cmex), the AMS symbol fonts (msam, msbm) and Euler (euex,
# eufm, eurm, eusm). pdfTeX and dvipdfm name glyphs this way in /Differences and often write no
# ToUnicode. Each character was chosen from the glyph's shape in the AMSFonts Type 1 fonts, the
# LaTeX command that draws it (amssymb.dtx, for msam and msbm) and Unicode's name for it, not
# copied from TeX's own list (texglyphlist.txt, GPL-2.0-only), which is read only to compare with
# (TEX_DIFFERS).
#
# A name means one character whatever the font, and a few names mean two symbols in two fonts.
# The value is the more common font's: cmmi's triangleleft and triangleright (◁ ▷; msam's are
# \vartriangleleft ⊲ and \vartriangleright ⊳), cmmi's star (⋆; msam's is \bigstar ★), cmsy's
# circleminus (⊖; msam's is \circleddash ⊝), cmsy's triangle and triangleinv (△ ▽; msam's are the
# small \vartriangle and \triangledown), and msam's followsorequal and precedesorequal (≿ ≾;
# msbm's are \succapprox ⪸ and \precapprox ⪷).
#
# Left out, and so unmapped: lasy, line and lcircle name their glyphs a1 to a61, which are ITC Zapf
# Dingbats names and the names many Type 3 fonts give their glyphs; wncy (Washington Cyrillic)
# names its Cyrillic letters with Latin names that the AGL reads as Latin, so its other names
# alone would give mixed text.
TEX_NAMES = {
    "Ifractur": "BLACK-LETTER CAPITAL I",
    "Rfractur": "BLACK-LETTER CAPITAL R",
    "angbracketleft": "MATHEMATICAL LEFT ANGLE BRACKET",
    "angbracketright": "MATHEMATICAL RIGHT ANGLE BRACKET",
    "arrowbothv": "UP DOWN ARROW",
    "arrowdblbothv": "UP DOWN DOUBLE ARROW",
    "arrowleftbothalf": "LEFTWARDS HARPOON WITH BARB DOWNWARDS",
    "arrowlefttophalf": "LEFTWARDS HARPOON WITH BARB UPWARDS",
    "arrownortheast": "NORTH EAST ARROW",
    "arrownorthwest": "NORTH WEST ARROW",
    "arrowrightbothalf": "RIGHTWARDS HARPOON WITH BARB DOWNWARDS",
    "arrowrighttophalf": "RIGHTWARDS HARPOON WITH BARB UPWARDS",
    "arrowsoutheast": "SOUTH EAST ARROW",
    "arrowsouthwest": "SOUTH WEST ARROW",
    "bardbl": "DOUBLE VERTICAL LINE",
    "ceilingleft": "LEFT CEILING",
    "ceilingright": "RIGHT CEILING",
    # Plain TeX's \copyright draws a c, then this circle over it.
    "circlecopyrt": "COMBINING ENCLOSING CIRCLE",
    "circledivide": "CIRCLED DIVISION SLASH",
    "circledot": "CIRCLED DOT OPERATOR",
    "circleminus": "CIRCLED MINUS",
    # cmsy's is \amalg, a binary operator; cmex's big one is coproducttext.
    "coproduct": "AMALGAMATION OR COPRODUCT",
    "diamondmath": "DIAMOND OPERATOR",
    # cmmi's "epsilon" is the two-bowl one, which the AGL maps to U+03B5.
    "epsilon1": "GREEK LUNATE EPSILON SYMBOL",
    "equivasymptotic": "EQUIVALENT TO",
    "flat": "MUSIC FLAT SIGN",
    "floorleft": "LEFT FLOOR",
    "floorright": "RIGHT FLOOR",
    "follows": "SUCCEEDS",
    "followsequal": "SUCCEEDS ABOVE SINGLE-LINE EQUALS SIGN",
    "greatermuch": "MUCH GREATER-THAN",
    "hatwide": "MODIFIER LETTER CIRCUMFLEX ACCENT",
    "hatwider": "MODIFIER LETTER CIRCUMFLEX ACCENT",
    "hatwidest": "MODIFIER LETTER CIRCUMFLEX ACCENT",
    "intersectionsq": "SQUARE CAP",
    "latticetop": "DOWN TACK",
    "lessmuch": "MUCH LESS-THAN",
    "lscript": "SCRIPT SMALL L",
    "natural": "MUSIC NATURAL SIGN",
    # \not: drawn over the relation that follows it.
    "negationslash": "COMBINING LONG SOLIDUS OVERLAY",
    "owner": "CONTAINS AS MEMBER",
    "pi1": "GREEK PI SYMBOL",
    "precedesequal": "PRECEDES ABOVE SINGLE-LINE EQUALS SIGN",
    "prime": "PRIME",
    "rho1": "GREEK RHO SYMBOL",
    "sharp": "MUSIC SHARP SIGN",
    "similarequal": "ASYMPTOTICALLY EQUAL TO",
    "slurabove": "FROWN",
    "slurbelow": "SMILE",
    "star": "STAR OPERATOR",
    "subsetsqequal": "SQUARE IMAGE OF OR EQUAL TO",
    "supersetsqequal": "SQUARE ORIGINAL OF OR EQUAL TO",
    "tie": "CHARACTER TIE",
    "tildewide": "SMALL TILDE",
    "tildewider": "SMALL TILDE",
    "tildewidest": "SMALL TILDE",
    "triangle": "WHITE UP-POINTING TRIANGLE",
    "triangleinv": "WHITE DOWN-POINTING TRIANGLE",
    "triangleleft": "WHITE LEFT-POINTING TRIANGLE",
    "triangleright": "WHITE RIGHT-POINTING TRIANGLE",
    "turnstileleft": "RIGHT TACK",
    "turnstileright": "LEFT TACK",
    "unionmulti": "MULTISET UNION",
    "unionsq": "SQUARE CUP",
    # The math accent \vec; Unicode has no spacing form.
    "vector": "COMBINING RIGHT ARROW ABOVE",
    "visiblespace": "OPEN BOX",
    "wreathproduct": "WREATH PRODUCT",
    # msam, by the command amssymb gives each glyph.
    "Yen": "YEN SIGN",
    "anticlockwise": "ANTICLOCKWISE GAPPED CIRCLE ARROW",
    "arrowparrleftright": "LEFTWARDS ARROW OVER RIGHTWARDS ARROW",
    "arrowparrrightleft": "RIGHTWARDS ARROW OVER LEFTWARDS ARROW",
    "arrowtailleft": "LEFTWARDS ARROW WITH TAIL",
    "arrowtailright": "RIGHTWARDS ARROW WITH TAIL",
    "arrowtripleleft": "LEFTWARDS TRIPLE ARROW",
    "arrowtripleright": "RIGHTWARDS TRIPLE ARROW",
    "between": "BETWEEN",
    "check": "CHECK MARK",
    "circleR": "REGISTERED SIGN",
    "circleS": "CIRCLED LATIN CAPITAL LETTER S",
    "circleasterisk": "CIRCLED ASTERISK OPERATOR",
    "circleequal": "RING EQUAL TO",
    "circlering": "CIRCLED RING OPERATOR",
    "clockwise": "CLOCKWISE GAPPED CIRCLE ARROW",
    "complement": "COMPLEMENT",
    "curlyleft": "LEFTWARDS ARROW WITH LOOP",
    "curlyright": "RIGHTWARDS ARROW WITH LOOP",
    "dblarrowdwn": "DOWNWARDS PAIRED ARROWS",
    "dblarrowheadleft": "LEFTWARDS TWO HEADED ARROW",
    "dblarrowheadright": "RIGHTWARDS TWO HEADED ARROW",
    "dblarrowup": "UPWARDS PAIRED ARROWS",
    "defines": "DELTA EQUAL TO",
    "diamondsolid": "BLACK LOZENGE",
    "difference": "DIFFERENCE BETWEEN",
    "dotplus": "DOT PLUS",
    "downfall": "CURLY LOGICAL OR",
    "equaldotleftright": "APPROXIMATELY EQUAL TO OR THE IMAGE OF",
    "equaldotrightleft": "IMAGE OF OR APPROXIMATELY EQUAL TO",
    "equalorfollows": "EQUAL TO OR SUCCEEDS",
    "equalorgreater": "SLANTED EQUAL TO OR GREATER-THAN",
    "equalorless": "SLANTED EQUAL TO OR LESS-THAN",
    "equalorprecedes": "EQUAL TO OR PRECEDES",
    "equalsdots": "GEOMETRICALLY EQUAL TO",
    "followsorcurly": "SUCCEEDS OR EQUAL TO",
    "followsorequal": "SUCCEEDS OR EQUIVALENT TO",
    "forces": "FORCES",
    "forcesbar": "TRIPLE VERTICAL BAR RIGHT TURNSTILE",
    "fork": "PITCHFORK",
    "frown": "FROWN",
    "geomequivalent": "GEOMETRICALLY EQUIVALENT TO",
    "greaterdbleqlless": "GREATER-THAN ABOVE DOUBLE-LINE EQUAL ABOVE LESS-THAN",
    "greaterdblequal": "GREATER-THAN OVER EQUAL TO",
    "greaterlessequal": "GREATER-THAN EQUAL TO OR LESS-THAN",
    "greaterorapproxeql": "GREATER-THAN OR APPROXIMATE",
    "greaterorequalslant": "GREATER-THAN OR SLANTED EQUAL TO",
    "greaterorsimilar": "GREATER-THAN OR EQUIVALENT TO",
    "harpoondownleft": "DOWNWARDS HARPOON WITH BARB LEFTWARDS",
    "harpoondownright": "DOWNWARDS HARPOON WITH BARB RIGHTWARDS",
    "harpoonleftright": "RIGHTWARDS HARPOON OVER LEFTWARDS HARPOON",
    "harpoonrightleft": "LEFTWARDS HARPOON OVER RIGHTWARDS HARPOON",
    "harpoonupleft": "UPWARDS HARPOON WITH BARB LEFTWARDS",
    "harpoonupright": "UPWARDS HARPOON WITH BARB RIGHTWARDS",
    "intercal": "INTERCALATE",
    "intersectiondbl": "DOUBLE INTERSECTION",
    "lessdbleqlgreater": "LESS-THAN ABOVE DOUBLE-LINE EQUAL ABOVE GREATER-THAN",
    "lessdblequal": "LESS-THAN OVER EQUAL TO",
    "lessequalgreater": "LESS-THAN EQUAL TO OR GREATER-THAN",
    "lessorapproxeql": "LESS-THAN OR APPROXIMATE",
    "lessorequalslant": "LESS-THAN OR SLANTED EQUAL TO",
    "lessorsimilar": "LESS-THAN OR EQUIVALENT TO",
    "maltesecross": "MALTESE CROSS",
    "measuredangle": "MEASURED ANGLE",
    "multimap": "MULTIMAP",
    "multiopenleft": "LEFT SEMIDIRECT PRODUCT",
    "multiopenright": "RIGHT SEMIDIRECT PRODUCT",
    "nand": "NAND",
    "orunderscore": "XOR",
    "perpcorrespond": "LOGICAL AND WITH DOUBLE OVERBAR",
    "precedesorcurly": "PRECEDES OR EQUAL TO",
    "precedesorequal": "PRECEDES OR EQUIVALENT TO",
    "primereverse": "REVERSED PRIME",
    "revasymptequal": "REVERSED TILDE EQUALS",
    "revsimilar": "REVERSED TILDE",
    "rightanglene": "TOP RIGHT CORNER",
    "rightanglenw": "TOP LEFT CORNER",
    "rightanglese": "BOTTOM RIGHT CORNER",
    "rightanglesw": "BOTTOM LEFT CORNER",
    "ringinequal": "RING IN EQUAL TO",
    "satisfies": "TRUE",
    "shiftleft": "UPWARDS ARROW WITH TIP LEFTWARDS",
    "shiftright": "UPWARDS ARROW WITH TIP RIGHTWARDS",
    "smile": "SMILE",
    "sphericalangle": "SPHERICAL ANGLE",
    "square": "WHITE SQUARE",
    "squaredot": "SQUARED DOT OPERATOR",
    "squareimage": "SQUARE IMAGE OF",
    "squareminus": "SQUARED MINUS",
    "squaremultiply": "SQUARED TIMES",
    "squareoriginal": "SQUARE ORIGINAL OF",
    "squareplus": "SQUARED PLUS",
    "squaresmallsolid": "BLACK SMALL SQUARE",
    "squaresolid": "BLACK SQUARE",
    "squiggleleftright": "LEFT RIGHT WAVE ARROW",
    "squiggleright": "RIGHTWARDS SQUIGGLE ARROW",
    "subsetdbl": "DOUBLE SUBSET",
    "subsetdblequal": "SUBSET OF ABOVE EQUALS SIGN",
    "supersetdbl": "DOUBLE SUPERSET",
    "supersetdblequal": "SUPERSET OF ABOVE EQUALS SIGN",
    "triangledownsld": "BLACK DOWN-POINTING TRIANGLE",
    "triangleleftequal": "NORMAL SUBGROUP OF OR EQUAL TO",
    "triangleleftsld": "BLACK LEFT-POINTING TRIANGLE",
    "trianglerightequal": "CONTAINS AS NORMAL SUBGROUP OR EQUAL TO",
    "trianglerightsld": "BLACK RIGHT-POINTING TRIANGLE",
    "trianglesolid": "BLACK UP-POINTING TRIANGLE",
    "uniondbl": "DOUBLE UNION",
    "uprise": "CURLY LOGICAL AND",
    # msbm. A negated relation Unicode has no character for (a double-line or slanted equals
    # with a stroke) is the negated plain relation: the same relation, drawn another way.
    "Digamma": "GREEK SMALL LETTER DIGAMMA",
    "Finv": "TURNED CAPITAL F",
    "Gmir": "TURNED SANS-SERIF CAPITAL G",
    "Omegainv": "INVERTED OHM SIGN",
    "approxorequal": "ALMOST EQUAL OR EQUAL TO",
    "archleftdown": "ANTICLOCKWISE TOP SEMICIRCLE ARROW",
    "archrightdown": "CLOCKWISE TOP SEMICIRCLE ARROW",
    "barshort": "DIVIDES",
    "beth": "BET SYMBOL",
    "daleth": "DALET SYMBOL",
    "dividemultiply": "DIVISION TIMES",
    "downslope": "BIG REVERSE SOLIDUS",
    "epsiloninv": "GREEK REVERSED LUNATE EPSILON SYMBOL",
    "equalorsimilar": "MINUS TILDE",
    "follownotdbleqv": "SUCCEEDS ABOVE NOT ALMOST EQUAL TO",
    "follownotslnteql": "SUCCEEDS ABOVE NOT EQUAL TO",
    "followornoteqvlnt": "SUCCEEDS BUT NOT EQUIVALENT TO",
    "greaterdot": "GREATER-THAN WITH DOT",
    "greaternotdblequal": "GREATER-THAN AND NOT APPROXIMATE",
    "greaternotequal": "GREATER-THAN AND SINGLE-LINE NOT EQUAL TO",
    "greaterornotdbleql": "GREATER-THAN BUT NOT EQUAL TO",
    "greaterornotequal": "GREATER-THAN BUT NOT EQUAL TO",
    "greaterornotsimilar": "GREATER-THAN BUT NOT EQUIVALENT TO",
    "integerdivide": "SET MINUS",
    "lessdot": "LESS-THAN WITH DOT",
    "lessnotdblequal": "LESS-THAN AND NOT APPROXIMATE",
    "lessnotequal": "LESS-THAN AND SINGLE-LINE NOT EQUAL TO",
    "lessornotdbleql": "LESS-THAN BUT NOT EQUAL TO",
    "lessornotequal": "LESS-THAN BUT NOT EQUAL TO",
    "lessornotsimilar": "LESS-THAN BUT NOT EQUIVALENT TO",
    "multicloseleft": "LEFT NORMAL FACTOR SEMIDIRECT PRODUCT",
    "multicloseright": "RIGHT NORMAL FACTOR SEMIDIRECT PRODUCT",
    "notapproxequal": "NEITHER APPROXIMATELY NOR ACTUALLY EQUAL TO",
    "notarrowboth": "LEFT RIGHT ARROW WITH STROKE",
    "notarrowleft": "LEFTWARDS ARROW WITH STROKE",
    "notarrowright": "RIGHTWARDS ARROW WITH STROKE",
    "notbar": "DOES NOT DIVIDE",
    "notdblarrowboth": "LEFT RIGHT DOUBLE ARROW WITH STROKE",
    "notdblarrowleft": "LEFTWARDS DOUBLE ARROW WITH STROKE",
    "notdblarrowright": "RIGHTWARDS DOUBLE ARROW WITH STROKE",
    "notexistential": "THERE DOES NOT EXIST",
    "notfollows": "DOES NOT SUCCEED",
    "notfollowsoreql": "DOES NOT SUCCEED OR EQUAL",
    "notforces": "DOES NOT FORCE",
    "notforcesextra": "NEGATED DOUBLE VERTICAL BAR DOUBLE RIGHT TURNSTILE",
    "notgreaterdblequal": "NEITHER GREATER-THAN NOR EQUAL TO",
    "notgreaterequal": "NEITHER GREATER-THAN NOR EQUAL TO",
    "notgreaterorslnteql": "NEITHER GREATER-THAN NOR EQUAL TO",
    "notlessdblequal": "NEITHER LESS-THAN NOR EQUAL TO",
    "notlessequal": "NEITHER LESS-THAN NOR EQUAL TO",
    "notlessorslnteql": "NEITHER LESS-THAN NOR EQUAL TO",
    "notprecedesoreql": "DOES NOT PRECEDE OR EQUAL",
    "notsatisfies": "NOT TRUE",
    "notshortbar": "DOES NOT DIVIDE",
    "notshortparallel": "NOT PARALLEL TO",
    "notsimilar": "NOT TILDE",
    "notsubseteql": "NEITHER A SUBSET OF NOR EQUAL TO",
    "notsubsetordbleql": "NEITHER A SUBSET OF NOR EQUAL TO",
    "notsubsetoreql": "SUBSET OF WITH NOT EQUAL TO",
    "notsuperseteql": "NEITHER A SUPERSET OF NOR EQUAL TO",
    "notsupersetordbleql": "NEITHER A SUPERSET OF NOR EQUAL TO",
    "notsupersetoreql": "SUPERSET OF WITH NOT EQUAL TO",
    "nottriangeqlleft": "NOT NORMAL SUBGROUP OF OR EQUAL TO",
    "nottriangeqlright": "DOES NOT CONTAIN AS NORMAL SUBGROUP OR EQUAL",
    "nottriangleleft": "NOT NORMAL SUBGROUP OF",
    "nottriangleright": "DOES NOT CONTAIN AS NORMAL SUBGROUP",
    "notturnstile": "DOES NOT PROVE",
    "parallelshort": "PARALLEL TO",
    "planckover2pi": "PLANCK CONSTANT OVER TWO PI",
    "planckover2pi1": "PLANCK CONSTANT OVER TWO PI",
    "precedenotdbleqv": "PRECEDES ABOVE NOT ALMOST EQUAL TO",
    "precedenotslnteql": "PRECEDES ABOVE NOT EQUAL TO",
    "precedeornoteqvlnt": "PRECEDES BUT NOT EQUIVALENT TO",
    "subsetnoteql": "SUBSET OF WITH NOT EQUAL TO",
    "subsetornotdbleql": "SUBSET OF ABOVE NOT EQUAL TO",
    "subsetornoteql": "SUBSET OF ABOVE NOT EQUAL TO",
    "supersetnoteql": "SUPERSET OF WITH NOT EQUAL TO",
    "supersetornotdbleql": "SUPERSET OF ABOVE NOT EQUAL TO",
    "supersetornoteql": "SUPERSET OF ABOVE NOT EQUAL TO",
    "upslope": "BIG SOLIDUS",
}
# Euler Fraktur's second shapes of a letter or digit (eufm, eufb): <name>alt and <name>nos are the
# character the AGL gives <name>.
TEX_SECOND_SHAPES = ("Yalt", "Zalt", "dalt", "dnos", "falt", "fnos", "galt", "kalt", "onealt", "talt", "ualt")
# cmex's delimiters in four sizes: <name>big, Big, bigg, Bigg are the same character.
TEX_SIZED = {
    "angbracketleft": "MATHEMATICAL LEFT ANGLE BRACKET",
    "angbracketright": "MATHEMATICAL RIGHT ANGLE BRACKET",
    "backslash": "REVERSE SOLIDUS",
    "braceleft": "LEFT CURLY BRACKET",
    "braceright": "RIGHT CURLY BRACKET",
    "bracketleft": "LEFT SQUARE BRACKET",
    "bracketright": "RIGHT SQUARE BRACKET",
    "ceilingleft": "LEFT CEILING",
    "ceilingright": "RIGHT CEILING",
    "floorleft": "LEFT FLOOR",
    "floorright": "RIGHT FLOOR",
    "parenleft": "LEFT PARENTHESIS",
    "parenright": "RIGHT PARENTHESIS",
    "radical": "SQUARE ROOT",
    "slash": "SOLIDUS",
}
# cmex's big operators in two sizes: <name>text and <name>display are the same character.
TEX_OPERATORS = {
    "circledot": "N-ARY CIRCLED DOT OPERATOR",
    "circlemultiply": "N-ARY CIRCLED TIMES OPERATOR",
    "circleplus": "N-ARY CIRCLED PLUS OPERATOR",
    "contintegral": "CONTOUR INTEGRAL",
    "coproduct": "N-ARY COPRODUCT",
    "integral": "INTEGRAL",
    "intersection": "N-ARY INTERSECTION",
    "logicaland": "N-ARY LOGICAL AND",
    "logicalor": "N-ARY LOGICAL OR",
    "product": "N-ARY PRODUCT",
    "summation": "N-ARY SUMMATION",
    "union": "N-ARY UNION",
    "unionmulti": "N-ARY UNION OPERATOR WITH PLUS",
    "unionsq": "N-ARY SQUARE UNION OPERATOR",
}
# Pieces TeX puts together into one symbol (an extensible arrow, brace or radical, the hook of
# \hookrightarrow, the bar of \mapsto and of the Ł in cmr's OT1, msam's head and bar of the dashed
# arrows), and Euler's empty "ghost". No character stands for one, so it stays unmapped.
TEX_PIECES = {
    "arrowaxisleft", "arrowaxisright", "arrowbt", "arrowdblbt", "arrowdbltp", "arrowhookleft",
    "arrowhookright", "arrowtp", "arrowvertexdbl", "axisshort", "bracehtipdownleft",
    "bracehtipdownright", "bracehtipupleft", "bracehtipupright", "ghost", "mapsto", "radicalbt",
    "radicaltp", "radicalvertex", "suppress", "vextenddouble", "vextendsingle",
}
# The AMSFonts fonts whose names TEX_NAMES and TEX_PIECES must cover, by file name prefix.
TEX_FONTS = ("cm", "eu", "msam", "msbm", "lcmss")
# Where TEX_NAMES and texglyphlist.txt's first value differ, and why.
NEGATED = ("texglyphlist gives the relation and U+0338, two code points; this table has one per "
           "name, and the negated plain relation is the same relation")
TEX_DIFFERS = {
    "bardbl": "TeX's \\| and \\Vert, which DOUBLE VERTICAL LINE is; \\parallel (texglyphlist's PARALLEL TO) "
              "is the same glyph used as a relation",
    "Digamma": "the letter, as the AGL maps the other Greek letters, not texglyphlist's MATHEMATICAL BOLD "
               "SMALL DIGAMMA",
    "circleequal": "\\circeq: a small ring over two lines, which RING EQUAL TO is, not texglyphlist's CIRCLED "
                   "EQUALS",
    "diamondsolid": "\\blacklozenge: a lozenge, taller than it is wide, not texglyphlist's BLACK DIAMOND SUIT",
    "notfollowsoreql": NEGATED,
    "notgreaterdblequal": NEGATED,
    "notgreaterorslnteql": NEGATED,
    "notlessdblequal": NEGATED,
    "notlessorslnteql": NEGATED,
    "notprecedesoreql": NEGATED,
    "notsubsetordbleql": NEGATED,
    "notsupersetordbleql": NEGATED,
}


def tex_names(src, agl):
    """TEX_NAMES, TEX_SIZED, TEX_OPERATORS and TEX_SECOND_SHAPES as {name: code point}. Fails unless they and
    TEX_PIECES are exactly the AGL-less names the TEX_FONTS encode, no name is in the AGL, and
    every difference from texglyphlist.txt is in TEX_DIFFERS (and nothing else is)."""
    names = {n: unicodedata.lookup(u) for n, u in TEX_NAMES.items()}
    for base, u in TEX_SIZED.items():
        for size in ("big", "Big", "bigg", "Bigg"):
            names[base + size] = unicodedata.lookup(u)
    for base, u in TEX_OPERATORS.items():
        for size in ("text", "display"):
            names[base + size] = unicodedata.lookup(u)
    names = {n: ord(c) for n, c in names.items()}
    for n in TEX_SECOND_SHAPES:
        assert n.endswith(("alt", "nos")) and n[:-3] in agl, n
        names[n] = agl[n[:-3]]
    assert not (names.keys() & agl.keys()), sorted(names.keys() & agl.keys())
    assert not (names.keys() & TEX_PIECES), sorted(names.keys() & TEX_PIECES)

    encoded = set()
    fonts = sorted(p for p in (src / "amsfonts").glob("*.pfb") if p.name.startswith(TEX_FONTS))
    for prefix in TEX_FONTS:
        assert any(p.name.startswith(prefix) for p in fonts), (prefix, src / "amsfonts")
    for path in fonts:
        font = t1Lib.T1Font(str(path))
        font.parse()
        encoded |= {n for n in font.font["Encoding"] if n != ".notdef" and n not in agl}
    assert encoded == names.keys() | TEX_PIECES, (sorted(encoded - names.keys() - TEX_PIECES),
                                                  sorted(names.keys() - encoded), sorted(TEX_PIECES - encoded))

    differs = set()
    for line in (src / "texglyphlist.txt").read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        name, values = line.split(";")
        if name in TEX_PIECES:
            differs.add(name)
        elif name in names and values.split(",")[0] != f"{names[name]:04X}":
            differs.add(name)
    assert differs == TEX_DIFFERS.keys(), (sorted(differs - TEX_DIFFERS.keys()), sorted(TEX_DIFFERS.keys() - differs))
    return names


def afm(path):
    """(copyright lines, [(code, width, name)])"""
    notices, glyphs = [], []
    for line in path.read_text(encoding="latin-1").splitlines():
        if line.startswith("Comment Copyright") or line.startswith("Notice "):
            notices.append(line)
        if line.startswith("C "):
            fields = dict(f.strip().split(" ", 1) for f in line.split(";") if f.strip())
            glyphs.append((int(fields["C"]), int(float(fields["WX"])), fields["N"]))
    return notices, glyphs


def vertical(path):
    """The AFM's Ascender and Descender. Every text font's AFM has both; a missing one is an error."""
    found = {}
    for line in path.read_text(encoding="latin-1").splitlines():
        key, _, value = line.partition(" ")
        if key in ("Ascender", "Descender"):
            found[key] = int(value)
    return found["Ascender"], found["Descender"]


def main():
    src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    agl = {}
    for line in (src / "glyphlist.txt").read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        name, codes = line.split(";")
        cps = codes.split()
        if len(cps) == 1:
            agl[name] = int(cps[0], 16)
    zapf = {}
    for line in (src / "zapfdingbats.txt").read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        name, code = line.split(";")
        zapf[name] = int(code, 16)
    tex = tex_names(src, agl)
    must_read = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]*>", " ", (src / "MustRead.html").read_text()))).strip()

    o = []
    o.append("//! Generated by tools/gen-read-tables.py; do not edit. See that file for the sources.")
    o.append("//!")
    o.append("//! The widths below are taken from Adobe's Core 14 AFM files (modified: reduced to")
    o.append("//! advance widths, re-keyed by Unicode code point, and each text font's Ascender and")
    o.append("//! Descender). Their notices, kept as Adobe's terms require:")
    notices_seen = set()
    for font in TEXT_FONTS + SYMBOLIC:
        notices, _ = afm(src / f"{font}.afm")
        for n in notices:
            if n not in notices_seen:
                notices_seen.add(n)
                o.append(f"//!   {font}: {n}")
    o.append("//! Adobe's MustRead.html, which accompanies the AFM files:")
    words, line = must_read.split(" "), ""
    for w in words:
        if len(line) + len(w) > 92:
            o.append(f"//!   {line.rstrip()}")
            line = ""
        line += w + " "
    o.append(f"//!   {line.rstrip()}")
    o.append("//! The glyph names are the Adobe Glyph List, glyphlist.txt, BSD-3-Clause, Copyright 2002-2019")
    o.append("//! Adobe (https://github.com/adobe-type-tools/agl-aglfn); the ZapfDingbats names are the ITC")
    o.append("//! Zapf Dingbats Glyph List, zapfdingbats.txt, from the same repository under the same terms.")
    o.append("//! The names of TeX's fonts that the AGL lacks are zpdf's own, from Unicode's names.")
    o.append("")
    o.append("pub const GlyphName = struct { name: []const u8, cp: u21 };")
    o.append("")
    o.append("/// The Adobe Glyph List, and the names of TeX's fonts that it lacks. Sorted by name (byte")
    o.append("/// order), for binary search.")
    o.append("pub const glyph_names = [_]GlyphName{")
    names = agl | tex
    for name in sorted(names, key=lambda n: n.encode()):
        o.append(f'    .{{ .name = "{name}", .cp = 0x{names[name]:04X} }},')
    o.append("};")
    o.append("")
    o.append("/// The ITC Zapf Dingbats Glyph List, sorted by name (byte order), for binary search.")
    o.append("pub const zapf_dingbats_names = [_]GlyphName{")
    for name in sorted(zapf, key=lambda n: n.encode()):
        o.append(f'    .{{ .name = "{name}", .cp = 0x{zapf[name]:04X} }},')
    o.append("};")

    def names_table(var, doc, names):
        o.append("")
        o.append(f"/// {doc}")
        o.append(f"pub const {var} = [256]?[]const u8{{")
        for code in range(256):
            n = names.get(code)
            o.append(f'    "{n}",' if n else "    null,")
        o.append("};")

    _, helv = afm(src / "Helvetica.afm")
    names_table("standard_encoding", "StandardEncoding: glyph name per code.", {c: n for c, _, n in helv if c >= 0})
    names_table("mac_roman_encoding", "MacRomanEncoding: glyph name per code.",
                {c: n for c, n in enumerate(MacRoman) if n and n != ".notdef" and c >= 32})

    # 391 strings, SID 0 to 390, ".notdef" first and "Semibold" last (TN 5176, Appendix A).
    assert len(cffStandardStrings) == 391 and cffStandardStrings[0] == ".notdef" and cffStandardStrings[390] == "Semibold"
    o.append("")
    o.append("/// CFF's standard strings by SID (Adobe TN 5176, Appendix A): a SID below 391 names one of")
    o.append("/// these; a larger one names a string in the font's own String INDEX.")
    o.append("pub const cff_standard_strings = [391][]const u8{")
    for name in cffStandardStrings:
        o.append(f'    "{name}",')
    o.append("};")

    o.append("")
    o.append("pub const CodePointWidth = struct { cp: u21, width: u16 };")
    o.append("")
    o.append("/// The 12 text fonts' widths, sorted by code point; glyphs with no single code point in the")
    o.append("/// glyph list are left out. ascender and descender are the AFM's, in 1/1000 em.")
    o.append("pub const text_font_widths = [_]struct { name: []const u8, ascender: i16, descender: i16, widths: []const CodePointWidth }{")
    for font in TEXT_FONTS:
        _, glyphs = afm(src / f"{font}.afm")
        ascender, descender = vertical(src / f"{font}.afm")
        by_cp = {}
        for _, w, n in glyphs:
            if n in agl:
                by_cp.setdefault(agl[n], w)
        o.append(f'    .{{ .name = "{font}", .ascender = {ascender}, .descender = {descender}, .widths = &.{{')
        for cp in sorted(by_cp):
            o.append(f"        .{{ .cp = 0x{cp:04X}, .width = {by_cp[cp]} }},")
        o.append("    } },")
    o.append("};")
    o.append("")
    o.append("/// Symbol and ZapfDingbats: width and glyph name per code of their built-in encoding.")
    o.append("pub const symbolic_fonts = [_]struct { name: []const u8, widths: [256]?u16, names: [256]?[]const u8 }{")
    for font in SYMBOLIC:
        _, glyphs = afm(src / f"{font}.afm")
        coded = {c: (w, n) for c, w, n in glyphs if c >= 0}
        ws = ", ".join(str(coded[c][0]) if c in coded else "null" for c in range(256))
        ns = ", ".join(f'"{coded[c][1]}"' if c in coded else "null" for c in range(256))
        o.append(f'    .{{ .name = "{font}", .widths = .{{ {ws} }}, .names = .{{ {ns} }} }},')
    o.append("};")
    out.write_text("\n".join(o) + "\n")


main()
