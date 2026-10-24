# /// script
# requires-python = ">=3.11"
# dependencies = ["pdfminer.six==20260107"]
# ///
"""Compares what zpdf.read reads from PDFs with two readers that share no code with it: MuPDF
(mutool, C) and pdfminer.six (Python).

    zig build && uv run tools/read-oracle.py [--verbose] <pdf or directory>...

Per file, zpdf-read's JSON (src/zpdf-read.zig) is checked against:
- "pages": the page count, against both readers, and each page's MediaBox and /Rotate, against
  pdfminer's own (never zpdf's) reading of them.
- "refused": a file zpdf.read refuses fails, unless it is encrypted (refused by design) or
  mutool also reports it damaged (zpdf.read does not repair). A page refused as unsupported
  (UnsupportedFont, UnsupportedFilter) is counted; any other page refusal fails.
- "text", against mutool draw -F stext: what mutool reads must be in what zpdf reads, and the
  runs that lie fully inside the page must be in what mutool reads (multisets of non-white-space
  characters). Both ways, because mutool leaves out ink that is off the page.
- "start": each run's first character must be at the run's origin, to 0.02 pt, in mutool's
  characters and in pdfminer's. A run fails only when every oracle that can measure it
  disagrees; one that only one oracle agrees with is counted as "only X agrees", because the
  two oracles disagree with each other (mutool's advances differ from /Widths on Cairo's files).
  ActualText runs are left out: their characters have no glyph each.
- "glyphs", against pdfminer with no layout analysis (one character per code drawn, in content
  order, as zpdf's glyphs are): every glyph's origin must be pdfminer's character's, to
  0.02 pt. This checks advances, Tc, Tw, Tz and TJ adjustments glyph by glyph. A glyph pdfminer
  places elsewhere but mutool has at its origin (same character) is counted as "only mutool
  agrees", as in "start".
- "order", against pdfminer: the characters of the runs, white space included, must be
  pdfminer's, in order. The glyphs of ActualText runs are left out on both sides (pdfminer
  ignores ActualText; mutool's "text" checks those).
- Annotation runs (the text of appearance streams, after the page's) are checked against mutool
  only: pdfminer reads no annotation, so "glyphs", "order" and its "start" vote leave them out.

Where an oracle deviates from ISO 32000-1, the deviation is undone or counted, never silently
excused; each one is in the code beside the place it applies:
- pdfminer places the character spacing before glyphs rather than after each one, leaves the text
  rise out of a glyph's origin, and takes a font's widths from its own metrics, ignoring /Widths,
  for the standard 14 and its aliases (all three undone in pdfminer_pages). Its metrics have no
  Euro width for Helvetica, so for such a font with no /Widths the glyphs after the gap must be
  off by one constant shift, which is counted.
- pdfminer reads codes in ways that differ from ISO 32000-1, undone in pdfminer_pages: WinAnsi
  0o255 as a space and no bullet for WinAnsi's unused codes (Annex D); Symbol and ZapfDingbats
  with no base encoding by a Latin encoding instead of their built-in ones (9.6.6.1); and a
  ToUnicode space kept over a later U+00A0 for the same code.
- pdfminer gives a ToUnicode value that is one UTF-16 half no character, and reads a CID font
  with no /ToUnicode through an older copy of its collection's CID-to-Unicode table than zpdf's.
  A page whose only differences in "order" are such glyphs is counted, and so is a "start" vote
  that needs them (order_explanations).
- mutool splits ligature characters unless asked not to (preserve-ligatures).
- mutool draw leaves out text that the clip hides completely (FZ_STEXT_CLIP, set by mudraw.c
  unless clip=no). zpdf gives all the text a page draws, so mutool is asked for it too (clip=no).
  mutool draw also records the page in a display list first, and playing the list back skips
  every command that lies fully outside the clip (fz_run_display_list, list-device.c), whatever
  the text options say; -D draws the page without the list. Without it, text drawn with render
  mode 4 to 6 reaches the text device twice, filled and as clip text; as many clip copies of each
  character are left out as pdfminer drew glyphs of it in those modes (counted).
- mutool replaces an unsigned signature field's appearance with MuPDF's own arrow labelled SIGN
  (pdf-appearance.c); those four letters are left out of its text (counted).
- mutool's text includes what a soft mask's group draws (MuPDF runs it through the same device,
  and its text device has no mask handler). A page whose only extra text in mutool is text drawn
  inside soft masks (its trace device, run on that page only) is counted (mutool_mask_text).
- MuPDF reads a code's character by rules of its own (mupdf_glyph_texts, mupdf_glyph_char): it
  ignores a ToUnicode value that is a control character, gives one that is a single UTF-16 half
  as that half (where zpdf joins two glyphs' halves), cuts glyph names at '_' but for five f
  ligatures, adds TeX's glyph names, and guesses from names AGL does not define (a20 as 20, G41
  through code page 437, g as a TrueType glyph index, digits as decimal). A page whose
  differences go when zpdf's glyphs are read by those rules is counted. Those glyphs' text is
  then checked against pdfminer only ("order"), which follows the AGL.
- mutool draw -F stext collects styles (FZ_STEXT_COLLECT_STYLES, set by mudraw.c for every text
  format but txt). With it, a glyph drawn twice at one place is given once (taken as fake bold),
  and the text MuPDF places on an image for an ActualText span with no glyph
  (fz_stext_end_metatext) is missing from the output, though txt has it. zpdf gives both, so
  mutool is asked without styles (collect-styles=no).
- mutool leaves out a glyph whose character equals the previous one when it starts less than 0.1
  times the size from where that one started (MuPDF's fake-bold rule that runs without
  collect-styles). zpdf gives every glyph drawn; a page whose only differences are such glyphs is
  counted, not failed (mupdf_fake_bold_drops).
- mutool maps a CID with no /ToUnicode through MuPDF's copy of Adobe's CID-to-Unicode table for
  the font's collection, which can be an older version than zpdf's (src/cid): MuPDF 1.28.5 has
  Adobe-Japan1-UCS2 8.004, zpdf 10.002. A page whose only text differences are pairs that the two
  versions give for one CID is counted, not failed (table_pairs, explained_by_tables).

Prints one line per file and the totals; with --verbose, the first difference of each failed
check. Exit status 1 when any check failed on any file.

Corpus: give it any PDFs. Pick them by producer, so the writers differ: what a file's Producer
says, not what its name or folder suggests.
"""

import collections
import functools
import html
import io
import json
import math
import pathlib
import re
import subprocess
import sys
import unicodedata
import urllib.request
import xml.etree.ElementTree as ET

ZPDF_READ = pathlib.Path(__file__).resolve().parent.parent / "zig-out/bin/zpdf-read"
TOL = 0.02


def zpdf(path):
    p = subprocess.run([ZPDF_READ, path], capture_output=True, text=True, timeout=120)
    if p.returncode not in (0, 1):
        return {"crash": p.returncode, "stderr": p.stderr[-500:]}
    try:
        return json.loads(p.stdout)
    except json.JSONDecodeError:
        return {"crash": f"exit {p.returncode}, no JSON", "stderr": p.stderr[-500:]}


def xml_allows(cp):
    return cp in (0x9, 0xA, 0xD) or 0x20 <= cp <= 0xD7FF or 0xE000 <= cp <= 0xFFFD or 0x10000 <= cp <= 0x10FFFF


# What a character XML forbids becomes on both sides: a private-use code point neither reader
# gives for a code, so it never matches a U+FFFD that a reader reported for an unmapped code.
XML_FORBIDDEN = 0x10FFFD

# fz_stext_char's flag for text the device received as clip text (structured-text.h).
STEXT_CLIPPED = 64


def xml_safe(text):
    """mutool writes characters XML 1.0 forbids (control characters, surrogates) as numeric
    references, which ElementTree refuses. Each becomes XML_FORBIDDEN, so the text check still sees
    a character there, instead of the file being skipped. zpdf's text gets the same replacement
    (as_mutool_reads), so a character both readers read compares equal."""

    def fix(m):
        cp = int(m.group(1)[1:], 16) if m.group(1)[0] in "xX" else int(m.group(1))
        return m.group(0) if xml_allows(cp) else f"&#x{XML_FORBIDDEN:X};"

    return re.sub(r"&#([xX][0-9a-fA-F]+|[0-9]+);", fix, text)


def as_mutool_reads(text):
    """zpdf's text with xml_safe's replacement applied, for comparing with mutool's."""
    return "".join(c if xml_allows(ord(c)) else chr(XML_FORBIDDEN) for c in text)


def mutool_pages(path):
    """(pages of ([(char, x, y)] in device space, [the same for characters flagged CLIPPED]),
    whether mutool reported damage), or (None, ...) when mutool cannot read the file."""
    # preserve-ligatures: mutool otherwise splits U+FB03 into "ffi", which is not what the file says.
    # clip=no: mutool otherwise leaves out text the clip hides; zpdf gives all the text drawn.
    # -D: without it, the display list drops text fully outside the clip before clip=no applies.
    # collect-styles=no: mutool otherwise drops a glyph drawn twice, and an image's ActualText.
    p = subprocess.run(["mutool", "draw", "-q", "-D", "-F", "stext", "-O", "preserve-ligatures,clip=no,collect-styles=no", "-o", "-", path], capture_output=True, timeout=120)
    damaged = b"repair" in p.stderr or b"broken" in p.stderr
    if p.returncode != 0:
        return None, damaged
    root = ET.fromstring(xml_safe(p.stdout.decode("utf-8", "replace")))
    pages = []
    for page in root.iter("page"):
        chars, clipped = [], []
        for ch in page.iter("char"):
            c = ch.get("c")
            if c is not None:
                (clipped if int(ch.get("flags", "0")) & STEXT_CLIPPED else chars).append((c, float(ch.get("x")), float(ch.get("y"))))
        # The characters the text device received as clip text, apart: see without_clip_copies.
        pages.append((chars, clipped))
    return pages, damaged


def pdfminer_pages(path):
    """(pages of {"media_box", "rotate", "chars": [(text, origin matrix, advance)]}, error)."""
    # Not high_level.extract_pages: it replaces laparams=None with LAParams(), whose layout
    # analysis reorders characters. The aggregator with no laparams keeps content order.
    from pdfminer.cmapdb import CMapParser, FileCMap, FileUnicodeMap, PyUnicodeMap
    from pdfminer.converter import PDFLayoutAnalyzer, PDFPageAggregator
    from pdfminer.encodingdb import EncodingDB, name2unicode
    from pdfminer.pdffont import FontMetricsDB, PDFCIDFont, PDFSimpleFont, PDFType1Font
    from pdfminer.layout import LTChar
    from pdfminer.pdfdevice import PDFTextDevice
    from pdfminer.pdfinterp import PDFPageInterpreter, PDFResourceManager
    from pdfminer.pdfpage import PDFPage
    from pdfminer.pdftypes import PDFStream, resolve1
    from pdfminer.psparser import LIT, PSLiteral, literal_name
    from pdfminer.utils import translate_matrix

    # pdfminer adds the character spacing (Tc) before a glyph, and only once a glyph or a TJ
    # number has come before it in the operator (pdfdevice.render_string_horizontal and _vertical,
    # needcharspace): an operator's first glyph gets no Tc, unless a number comes before it, and
    # then it is moved by Tc; the Tc after the last glyph is never added. ISO 32000-1 9.4.4 adds
    # Tc after every glyph; mutool does, and so does zpdf. Both are replaced by copies that do.
    if not hasattr(PDFTextDevice, "_zpdf_tc"):

        def tc_after_glyph(axis):
            def render(self, seq, matrix, pos, font, fontsize, scaling, charspace, wordspace, rise, dxscale, ncs, graphicstate):
                p = list(pos)
                for obj in seq:
                    if isinstance(obj, (int, float)):
                        p[axis] -= obj * dxscale
                    elif isinstance(obj, bytes):
                        for cid in font.decode(obj):
                            p[axis] += self.render_char(translate_matrix(matrix, tuple(p)), font, fontsize, scaling, rise, cid, ncs, graphicstate)
                            p[axis] += charspace
                            if cid == 32 and wordspace:
                                p[axis] += wordspace
                return tuple(p)

            return render

        PDFTextDevice.render_string_horizontal = tc_after_glyph(0)
        PDFTextDevice.render_string_vertical = tc_after_glyph(1)
        PDFTextDevice._zpdf_tc = True

    # pdfminer takes a simple font's widths from its own AFM data whenever it has metrics for the
    # /BaseFont (FontMetricsDB: the standard 14 and aliases such as Arial for Helvetica), and then
    # ignores the font's /Widths (PDFType1Font, also for TrueType). ISO 32000-1 9.6.2.1 and 9.6.3:
    # /Widths gives the widths; mutool and zpdf use them. When the font has /Widths, pdfminer is
    # made to read it as a font it has no metrics for, which takes /FirstChar, /Widths and the
    # /FontDescriptor from the file.
    if not hasattr(PDFType1Font, "_zpdf_widths"):
        type1_init = PDFType1Font.__init__
        get_metrics = FontMetricsDB.__dict__["get_metrics"]

        def no_metrics(cls, fontname):
            raise KeyError(fontname)

        def files_widths(self, rsrcmgr, spec):
            if "Widths" not in spec:
                return type1_init(self, rsrcmgr, spec)
            FontMetricsDB.get_metrics = classmethod(no_metrics)
            try:
                type1_init(self, rsrcmgr, spec)
            finally:
                FontMetricsDB.get_metrics = get_metrics

        PDFType1Font.__init__ = files_widths
        PDFType1Font._zpdf_widths = True

    # pdfminer never reads a CID font's /Encoding when it is an embedded CMap stream: it looks the
    # stream's /CMapName up among its predefined CMaps (PDFCIDFont.get_cmap_from_spec), and a
    # name it does not have gives an empty CMap, which decodes no code at all. ISO 32000-1
    # 9.7.5.3 allows the stream. It is read with pdfminer's own CMapParser instead, whose
    # cidrange and cidchar calls go to add_cid2unichr(cid, code): here they fill a FileCMap.
    if not hasattr(PDFCIDFont, "_zpdf_cmap"):
        cmap_from_spec = PDFCIDFont.get_cmap_from_spec

        def embedded_cmap(self, spec, strict):
            enc = resolve1(spec.get("Encoding"))
            if not isinstance(enc, PDFStream):
                return cmap_from_spec(self, spec, strict)
            cmap = FileCMap()
            cmap.add_cid2unichr = lambda cid, code: cmap.add_code2cid(code.decode("latin-1"), cid) if isinstance(code, bytes) else None
            CMapParser(cmap, io.BytesIO(enc.get_data())).run()
            if resolve1(enc.get("WMode")) == 1:
                cmap.set_attr("WMode", 1)
            return cmap

        PDFCIDFont.get_cmap_from_spec = embedded_cmap
        PDFCIDFont._zpdf_cmap = True

    # LTChar keeps the text rise only inside its bounding box; keep it, so a glyph's origin can
    # include it as zpdf's does (ISO 32000-1 9.4.4: the origin is (0, Ts) in text space).
    if not hasattr(LTChar, "_zpdf_rise"):
        init = LTChar.__init__

        def keep_rise(self, matrix, font, fontsize, scaling, rise, *rest):
            init(self, matrix, font, fontsize, scaling, rise, *rest)
            self._zpdf_rise = rise

        LTChar.__init__ = keep_rise
        LTChar._zpdf_rise = 0

    # Each character's font and code, for mupdf_glyph_texts: which /Differences name the code has
    # and what the font's ToUnicode gives it.
    if not hasattr(PDFLayoutAnalyzer, "_zpdf_code"):
        render = PDFLayoutAnalyzer.render_char

        def keep_code(self, matrix, font, fontsize, scaling, rise, cid, *rest):
            adv = render(self, matrix, font, fontsize, scaling, rise, cid, *rest)
            self.cur_item._objs[-1]._zpdf_code = (font, cid)
            self.cur_item._objs[-1]._zpdf_mode = getattr(self, "_zpdf_mode", 0)
            return adv

        # The text render mode of each character, for without_clip_copies.
        render_string = PDFTextDevice.render_string

        def keep_mode(self, textstate, *rest):
            self._zpdf_mode = textstate.render
            return render_string(self, textstate, *rest)

        PDFTextDevice.render_string = keep_mode

        PDFLayoutAnalyzer.render_char = keep_code
        PDFLayoutAnalyzer._zpdf_code = True
        simple = PDFSimpleFont.__init__

        def keep_spec(self, descriptor, widths, spec):
            simple(self, descriptor, widths, spec)
            self._zpdf_spec = spec
            builtin = symbolic_builtin(spec)
            if builtin is not None:
                self.cid2unicode = builtin

        PDFSimpleFont.__init__ = keep_spec

    # pdfminer's Latin table (latin_enc.py) has WinAnsi 0o255 as "space", where ISO 32000-1 Annex D
    # has "hyphen" (its note 5), and leaves out WinAnsi's unused codes above 0o40, which Annex D
    # maps to "bullet" (its note 3). Its table is corrected.
    if not hasattr(EncodingDB, "_zpdf_annex_d"):
        EncodingDB.win2unicode[0o255] = "-"
        for code in (0o177, 0o201, 0o215, 0o217, 0o220, 0o235):
            EncodingDB.win2unicode[code] = "•"
        EncodingDB._zpdf_annex_d = True

    # pdfminer keeps a ToUnicode space over a later U+00A0 for the same code (FileUnicodeMap,
    # cmapdb.py), where zpdf, MuPDF and pdf.js take the later one: undone. It also decodes each
    # value with "ignore", so a value that is one half of a UTF-16 pair becomes no character; the
    # half is kept instead, for the checks to see (order_explanations, mupdf_glyph_texts).
    if not hasattr(FileUnicodeMap, "_zpdf_kept"):
        add_cid2unichr = FileUnicodeMap.add_cid2unichr

        def keep_nbsp_and_halves(self, cid, code):
            add_cid2unichr(self, cid, code)
            if isinstance(code, PSLiteral):
                try:
                    unichr = name2unicode(code.name)
                except (KeyError, ValueError):
                    return
            elif isinstance(code, bytes):
                try:
                    unichr = code.decode("utf-16-be", "surrogatepass")
                except UnicodeDecodeError:
                    return
            else:
                unichr = chr(code)
            if unichr == " " or (len(unichr) == 1 and 0xD800 <= ord(unichr) <= 0xDFFF):
                self.cid2unichr[cid] = unichr

        FileUnicodeMap.add_cid2unichr = keep_nbsp_and_halves
        FileUnicodeMap._zpdf_kept = True

    def symbolic_builtin(spec):
        """pdfminer reads a Symbol or ZapfDingbats font with no base encoding by StandardEncoding
        (WinAnsi for TrueType), never by the font's built-in encoding, which 9.6.6.1 says is the
        base. For such a font that is not embedded, the codes' characters by its built-in encoding
        (builtin_encodings) with /Differences on top, as pdfminer reads /Differences
        (EncodingDB.get_encoding), but ZapfDingbats' names by Adobe's Zapf Dingbats list first; else
        None."""
        base_font = spec.get("BaseFont")
        name = literal_name(base_font) if isinstance(base_font, PSLiteral) else None
        if name not in ("Symbol", "ZapfDingbats"):
            return None
        descriptor = resolve1(spec.get("FontDescriptor"))
        if isinstance(descriptor, dict) and any(k in descriptor for k in ("FontFile", "FontFile2", "FontFile3")):
            return None
        enc = resolve1(spec.get("Encoding"))
        if enc is not None and not (isinstance(enc, dict) and "BaseEncoding" not in enc):
            return None
        tables = builtin_encodings()
        if tables is None:
            return None
        chars = dict(tables[name])
        code = 0
        for d in (resolve1(enc.get("Differences")) or []) if isinstance(enc, dict) else []:
            d = resolve1(d)
            if isinstance(d, int):
                code = d
            elif isinstance(d, PSLiteral):
                glyph = literal_name(d)
                if name == "ZapfDingbats" and glyph in zapf_dingbats_list():
                    chars[code] = zapf_dingbats_list()[glyph]
                else:
                    try:
                        chars[code] = name2unicode(glyph)
                    except (KeyError, ValueError):
                        pass
                code += 1
        return chars

    def walk(item, out, codes, modes, tables):
        if isinstance(item, LTChar):
            text = item.get_text()
            a, b, c, d, e, f = item.matrix
            r = item._zpdf_rise
            origin = (a, b, c, d, e + c * r, f + d * r)
            out.append((re.sub(r"\(cid:\d+\)", "�", text), origin, item.adv))
            codes.append(code_info(*item._zpdf_code))
            modes.append(item._zpdf_mode)
            tables.append(table_text(*item._zpdf_code))
        elif hasattr(item, "__iter__"):
            for child in item:
                walk(child, out, codes, modes, tables)

    def table_text(font, cid):
        """For a CID that pdfminer reads through its own copy of the font's collection's
        CID-to-Unicode table (a CID font with no /ToUnicode), what zpdf's copy (src/cid) gives it;
        else None."""
        if not isinstance(font, PDFCIDFont) or not isinstance(font.unicode_map, PyUnicodeMap):
            return None
        table = zpdf_cid_table(font.cidcoding)
        return None if table is None else table.get(cid)

    differences = {}

    def code_info(font, cid):
        """(its /Differences name or None, its ToUnicode value or None) for one drawn code."""
        if id(font) not in differences:
            names, code = {}, None
            enc = resolve1(getattr(font, "_zpdf_spec", {}).get("Encoding"))
            for d in (resolve1(enc.get("Differences")) or []) if isinstance(enc, dict) else []:
                d = resolve1(d)
                if isinstance(d, int):
                    code = d
                elif code is not None:
                    names[code] = literal_name(d)
                    code += 1
            differences[id(font)] = (font, names)
        to_unicode = None
        if getattr(font, "unicode_map", None) is not None:
            try:
                to_unicode = font.unicode_map.get_unichr(cid)
            except KeyError:
                pass
        return differences[id(font)][1].get(cid), to_unicode

    def inherited(d, key):
        for _ in range(32):
            if not isinstance(d, dict):
                return None
            if key in d:
                return resolve1(d[key])
            d = resolve1(d.get("Parent"))
        return None

    def unsigned_signature_rects(page):
        """The /Rect of each unsigned signature field's widget, in default user space: MuPDF draws
        its own "SIGN" arrow over these (without_signature_labels)."""
        rects = []
        for a in resolve1(page.annots) or []:
            a = resolve1(a)
            if not isinstance(a, dict) or literal_name(inherited(a, "FT")) != "Sig":
                continue
            v = inherited(a, "V")
            signed = isinstance(v, dict) and literal_name(v.get("Type", LIT("Sig"))) == "Sig"
            rect = [float(resolve1(n)) for n in resolve1(a.get("Rect")) or []]
            if not signed and len(rect) == 4:
                rects.append((min(rect[0], rect[2]), min(rect[1], rect[3]), max(rect[0], rect[2]), max(rect[1], rect[3])))
        return rects

    # Built here, outside the try below: a failure in it is the oracle's, not a file pdfminer
    # refuses, and must not skip the file's pdfminer checks.
    builtin_encodings()
    pages = []
    try:
        rsrc = PDFResourceManager()
        device = PDFPageAggregator(rsrc, laparams=None)
        interp = PDFPageInterpreter(rsrc, device)
        with open(path, "rb") as f:
            for page in PDFPage.get_pages(f):
                interp.process_page(page)
                out, codes, modes, tables = [], [], [], []
                walk(device.get_result(), out, codes, modes, tables)
                pages.append({"media_box": [float(v) for v in page.mediabox], "rotate": page.rotate % 360, "chars": out, "codes": codes, "modes": modes, "tables": tables, "unsigned_signatures": unsigned_signature_rects(page)})
    except Exception as e:  # pdfminer refuses some files; they are left out
        return None, str(e)[:120]
    return pages, None


def pdfminer_to_user(geom, point):
    """pdfminer's coordinates, which start from its page matrix (pdfinterp.process_page: the
    MediaBox origin moved to 0, 0, then /Rotate), back in default user space, from pdfminer's own
    reading of the box and rotation."""
    x0, y0, x1, y1 = geom["media_box"]
    a, b, c, d, e, f = {
        90: (0, -1, 1, 0, -y0, x1),
        180: (-1, 0, 0, -1, x1, y1),
        270: (0, 1, -1, 0, y1, -x0),
    }.get(geom["rotate"], (1, 0, 0, 1, -x0, -y0))
    det = a * d - b * c
    px, py = point[0] - e, point[1] - f
    return ((d * px - c * py) / det, (-b * px + a * py) / det)


def nonwhite(s):
    return "".join(s.split())


def glyph_texts(r):
    """Each glyph's characters in run r. A glyph's text_at is a UTF-8 byte offset into the run's
    text (src/read_text.zig, Glyph), not a character index."""
    b = r["text"].encode("utf-8")
    ats = [g["text_at"] for g in r["glyphs"]] + [len(b)]
    return [b[ats[n]:ats[n + 1]].decode("utf-8") for n in range(len(r["glyphs"]))]


# MuPDF's always-on fake-bold rule (source/fitz/stext-device.c, fz_add_stext_char_imp, 1.28.5):
# a glyph whose character equals the previous one, starting less than FAKE_BOLD_MAX_DIST times the
# size from where the previous one started, is not added; that previous glyph stays the one the
# next is measured from. Unlike check_for_fake_bold, it runs without collect-styles.
MUPDF_FAKE_BOLD_MAX_DIST = 0.1


def mupdf_fake_bold_drops(runs):
    """The characters mutool leaves out of zpdf's runs by MuPDF's always-on fake-bold rule, as a
    multiset. zpdf's runs are in drawing order, as MuPDF's characters are. An ActualText run, or a
    glyph of more than one character, starts over: what MuPDF does there is not modelled, so no
    drop is assumed, which can only fail a page, never excuse one."""
    drops = collections.Counter()
    prev = None
    for r in runs:
        if r["actual_text"]:
            prev = None
            continue
        for g, c in zip(r["glyphs"], glyph_texts(r)):
            if len(c) != 1 or r["size"] <= 0:
                prev = None
                continue
            if (prev is not None and prev[0] == c and prev[3] == r["vertical"]
                    and math.hypot(g["x"] - prev[1], g["y"] - prev[2]) / r["size"] < MUPDF_FAKE_BOLD_MAX_DIST):
                drops[c] += 1
                continue
            prev = (c, g["x"], g["y"], r["vertical"])
    return drops


def without_clip_copies(clipped, pm_page):
    """mutool's clip-text characters without the copies MuPDF makes of text drawn with render mode
    4, 5 or 6: without the display list (-D) such text reaches the text device twice, filled and
    again as clip text, a separate fz_text, which the device's repeat check (text == lasttext,
    stext-device.c) does not catch. For each character, as many clip copies are left out as
    pdfminer drew glyphs of it in those modes on the page; which ones does not matter to a check
    of multisets. Text drawn only as clip (mode 7), or drawn again by the file, keeps its
    characters; so does every clip character where pdfminer has no page."""
    if not clipped or pm_page is None:
        return list(clipped)
    drawn = collections.Counter(c[0] for (c, _, _), mode in zip(pm_page["chars"], pm_page["modes"]) if mode in (4, 5, 6) and c)
    kept = []
    for c, x, y in clipped:
        if drawn[c] > 0:
            drawn[c] -= 1
        else:
            kept.append((c, x, y))
    return kept


def without_signature_labels(chars, rects, crop_box):
    """mutool's characters on an unrotated page without the "SIGN" MuPDF draws on each unsigned
    signature field: it replaces such a widget's appearance, blank or not, with its own arrow
    labelled SIGN (pdf_update_appearance, pdf-appearance.c), text the file does not have. Only
    the four letters, in that order and inside the field's rectangle, are left out."""
    cx0, _, _, cy1 = crop_box
    out = list(chars)
    for x0, y0, x1, y1 in rects:
        left, top, right, bottom = x0 - cx0, cy1 - y1, x1 - cx0, cy1 - y0
        for k in range(len(out) - 3):
            label = out[k:k + 4]
            if "".join(c for c, _, _ in label) == "SIGN" and all(left <= x <= right and top <= y <= bottom for _, x, y in label):
                del out[k:k + 4]
                break
    return out


def zero_width_gap(c, adv):
    """pdfminer gave a printable, non-combining character no width: a gap in its metric tables
    (Helvetica's Euro), not the font's (Adobe's AFM and mutool give 556)."""
    return adv == 0 and c.strip() and not unicodedata.combining(c[0])


def ucs2_table(text):
    """{cid: text} from a CID-to-Unicode CMap (bfchar and bfrange over two-byte CIDs)."""
    def chars(h):
        return bytes.fromhex(h).decode("utf-16-be", "surrogatepass")

    out = {}
    for block in re.findall(r"beginbfchar(.*?)endbfchar", text, re.S):
        for cid, dst in re.findall(r"<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>", block):
            out[int(cid, 16)] = chars(dst)
    for block in re.findall(r"beginbfrange(.*?)endbfrange", text, re.S):
        for lo, hi, dst in re.findall(r"<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>\s*(<[0-9a-fA-F]+>|\[[^\]]*\])", block):
            lo, hi = int(lo, 16), int(hi, 16)
            if dst.startswith("["):
                for k, d in enumerate(re.findall(r"<([0-9a-fA-F]+)>", dst)):
                    out[lo + k] = chars(d)
            else:
                start = chars(dst[1:-1])
                for k in range(hi - lo + 1):
                    out[lo + k] = start[:-1] + chr(ord(start[-1]) + k)
    return out


@functools.cache
def zpdf_cid_table(collection):
    """{cid: text} of zpdf's CID-to-Unicode table for a collection ("Adobe-Japan1"), from
    src/cid, or None when zpdf has none for it."""
    path = pathlib.Path(__file__).resolve().parent.parent / "src/cid" / f"{collection}-UCS2"
    return ucs2_table(path.read_text(encoding="latin-1")) if path.is_file() else None


@functools.cache
def table_pairs():
    """The (zpdf's text, MuPDF's text) pairs the two readers' CID-to-Unicode tables give for one
    CID, over the collections both have: MuPDF's tables for the installed mutool's version, from
    its source tree (cached in .cache/zpdf-oracle in the home folder), against src/cid. None,
    with a note, when MuPDF's tables cannot be had: the differences then fail."""
    v = subprocess.run(["mutool", "-v"], capture_output=True, text=True)
    version = re.search(r"version (\S+)", v.stdout + v.stderr)
    if not version:
        print("note: mutool -v gave no version; CID-to-Unicode table differences fail")
        return None
    cache = pathlib.Path.home() / ".cache" / "zpdf-oracle" / f"mupdf-{version.group(1)}"
    pairs = set()
    for ordering in ("Japan1", "GB1", "CNS1", "Korea1"):
        name = f"Adobe-{ordering}-UCS2"
        theirs_path = cache / name
        if not theirs_path.exists():
            url = f"https://raw.githubusercontent.com/ArtifexSoftware/mupdf/{version.group(1)}/resources/cmaps/{name}"
            try:
                data = urllib.request.urlopen(url, timeout=60).read()
            except OSError as e:
                print(f"note: {url}: {e}; CID-to-Unicode table differences fail")
                return None
            cache.mkdir(parents=True, exist_ok=True)
            theirs_path.write_bytes(data)
        ours = zpdf_cid_table(f"Adobe-{ordering}")
        theirs = ucs2_table(theirs_path.read_text(encoding="latin-1"))
        for cid in ours.keys() | theirs.keys():
            a, b = ours.get(cid, "\ufffd"), theirs.get(cid, "\ufffd")
            if nonwhite(a) != nonwhite(b):
                pairs.add((nonwhite(a), nonwhite(b)))
    # Each pair as what it adds on each side: 通 + U+E0100 against 通 is one more U+E0100 in zpdf.
    reduced = {(frozenset((collections.Counter(a) - collections.Counter(b)).items()), frozenset((collections.Counter(b) - collections.Counter(a)).items())) for a, b in pairs}
    return [(collections.Counter(dict(z)), collections.Counter(dict(m))) for z, m in reduced if z or m]


def cached_download(url, name):
    """A file from `url`, kept in .cache/zpdf-oracle in the home folder under `name`. None, with a
    note, when it cannot be had."""
    path = pathlib.Path.home() / ".cache" / "zpdf-oracle" / name
    if not path.exists():
        try:
            data = urllib.request.urlopen(url, timeout=60).read()
        except OSError as e:
            print(f"note: {url}: {e}")
            return None
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return path.read_text(encoding="utf-8")


# Adobe's ITC Zapf Dingbats Glyph List, at a fixed commit of its repository.
AGL_COMMIT = "4036a9ca80a62f64f9de4f7321a9a045ad0ecfd6"


@functools.cache
def zapf_dingbats_list():
    """Adobe's ITC Zapf Dingbats Glyph List, character by glyph name, or None when it cannot be
    had."""
    zapf = cached_download(f"https://raw.githubusercontent.com/adobe-type-tools/agl-aglfn/{AGL_COMMIT}/zapfdingbats.txt", f"agl-{AGL_COMMIT}/zapfdingbats.txt")
    if zapf is None:
        return None
    out = {}
    for line in zapf.splitlines():
        if line and not line.startswith("#"):
            name, code = line.split(";")
            out[name] = chr(int(code, 16))
    return out


# pdf.js's tables of the standard encodings (src/core/encodings.js), at a fixed release.
PDFJS_TAG = "v4.10.38"


@functools.cache
def builtin_encodings():
    """{"Symbol": {code: char}, "ZapfDingbats": {code: char}}: the built-in encodings of the two
    symbolic standard fonts, by glyph name from pdf.js's tables (SymbolSetEncoding,
    ZapfDingbatsEncoding), a source apart from zpdf's (Adobe's AFM files), each name read as the
    AGL Specification says: ZapfDingbats' by Adobe's Zapf Dingbats list first, then each by the
    AGL (pdfminer's name2unicode). None when either cannot be had."""
    from pdfminer.encodingdb import name2unicode

    js = cached_download(f"https://raw.githubusercontent.com/mozilla/pdf.js/{PDFJS_TAG}/src/core/encodings.js", f"pdfjs-{PDFJS_TAG}/encodings.js")
    zapf = zapf_dingbats_list()
    if js is None or zapf is None:
        return None
    out = {}
    for font, array in (("Symbol", "SymbolSetEncoding"), ("ZapfDingbats", "ZapfDingbatsEncoding")):
        body = js[js.index(f"const {array} = ["):]
        names = re.findall(r'"([^"]*)"', body[:body.index("];")])
        assert len(names) == 256, (array, len(names))
        chars = {}
        for code, name in enumerate(names):
            if not name:
                continue
            chars[code] = zapf[name] if font == "ZapfDingbats" and name in zapf else name2unicode(name)
        out[font] = chars
    return out


@functools.cache
def mupdf_glyph_tables():
    """What MuPDF's fz_unicode_from_glyph_name reads, for the installed mutool's version, from
    its source tree: the glyph names it knows (glyphlist.h: the Adobe Glyph List, then TeX's
    texglyphlist.txt), and its code page 437 and TrueType glyph index tables (encodings.h). Plus
    Adobe's Zapf Dingbats list, name by character. None when any cannot be had: glyph-name
    differences then fail."""
    v = subprocess.run(["mutool", "-v"], capture_output=True, text=True)
    version = re.search(r"version (\S+)", v.stdout + v.stderr)
    if not version:
        return None
    base = f"https://raw.githubusercontent.com/ArtifexSoftware/mupdf/{version.group(1)}/source/fitz/"
    glyphs = cached_download(base + "glyphlist.h", f"mupdf-{version.group(1)}/glyphlist.h")
    encodings = cached_download(base + "encodings.h", f"mupdf-{version.group(1)}/encodings.h")
    zapf = zapf_dingbats_list()
    if glyphs is None or encodings is None or zapf is None:
        return None

    def array(text, start):
        body = text[text.index(start):]
        return body[body.index("{") + 1:body.index("};")]

    names = re.findall(r'"([^"]*)"', array(glyphs, "single_name_list[]"))
    codes = [int(c, 16) for c in re.findall(r"0x([0-9a-fA-F]+)", array(glyphs, "single_code_list[]"))]
    assert len(names) == len(codes), (len(names), len(codes))
    dos437 = [int(c) for c in re.findall(r"\d+", array(encodings, "fz_unicode_from_dos_437[256]"))]
    tt_index = [int(c) for c in re.findall(r"\d+", array(encodings, "fz_unicode_from_true_type_glyph_index[]"))]
    assert len(dos437) == 256 and len(tt_index) >= 258, (len(dos437), len(tt_index))
    zapf_names = {c: name for name, c in zapf.items()}
    return dict(zip(names, codes)), dos437, tt_index, zapf_names


def mupdf_glyph_char(name):
    """MuPDF's character for a glyph name (fz_unicode_from_glyph_name, encodings.c), which
    differs from the AGL Specification: the name is cut at its first '.'; f_f, f_f_i, f_f_l, f_i
    and f_l become the ligatures ff, ffi, ffl, fi, fl (U+FB00 to U+FB04), and any other name with
    a '_' is cut there; then its glyph list, which adds TeX's names; then uniXXXX (seven
    characters only), u and hex digits of any length, a and decimal digits, G and hex (code page
    437), g and hex (a TrueType glyph index), or decimal digits alone; else U+FFFD."""
    names, dos437, tt_index, _ = mupdf_glyph_tables()
    buf = name[:63].split(".", 1)[0]
    if "_" in buf:
        buf = buf.replace("_", "") if buf in ("f_f", "f_f_i", "f_f_l", "f_i", "f_l") else buf.split("_", 1)[0]
    if buf in names:
        return chr(names[buf])

    def num(digits, base):
        # strtol over the whole rest, as read_num does: an empty rest is 0.
        if not digits:
            return 0
        try:
            return int(digits, base) if "_" not in digits else 0
        except ValueError:
            return 0

    if buf.startswith("uni") and len(buf) == 7:
        code = num(buf[3:], 16)
    elif buf.startswith("u"):
        code = num(buf[1:], 16)
    elif buf.startswith("a") and len(buf) >= 3:
        code = num(buf[1:], 10)
    elif buf.startswith("G"):
        code = num(buf[1:], 16)
        code = dos437[code] if 0 < code < 256 else 0
    elif buf.startswith("g"):
        code = num(buf[1:], 16)
        code = tt_index[code] if 0 < code < 258 else 0
    else:
        code = num(buf, 10)
    return chr(code) if 0 < code <= 0x10FFFF else "\ufffd"


def mupdf_glyph_texts(runs, codes):
    """zpdf's runs' text as MuPDF would give it, where the two readers' rules for a code's
    character differ, or None when MuPDF's tables cannot be had. codes: pdfminer's (/Differences
    name, ToUnicode value) for each glyph of the page's content runs, in zpdf's glyph order, or
    None when the two do not have the same glyphs (an annotation's glyphs have none: pdfminer
    reads no annotation).

    MuPDF's character for a code (pdf_show_char, pdf-op-run.c): the ToUnicode value; a single
    value from U+0008 to U+000D is a space, and one below U+0020 or from U+007F to U+009F is
    ignored for the glyph name's character, as is no value; U+0000 is U+FFFD. A value that is one
    half of a UTF-16 pair is that half (pdf_map_one_to_many, pdf-cmap.c, joins halves only within
    one value), so two glyphs that zpdf joins into one character are two characters in mutool's
    text. A glyph name is read by mupdf_glyph_char. A ZapfDingbats glyph with no /Differences
    name has its name from zpdf's character through Adobe's Zapf Dingbats list (the built-in
    encoding's names, which zpdf reads by that list). ActualText runs are left as they are: their
    text is not their glyphs'. pdfminer's ToUnicode stands in for MuPDF's in telling which codes
    have a value."""
    tables = mupdf_glyph_tables()
    if tables is None:
        return None
    zapf_names = tables[3]
    out, j = [], 0
    for r in runs:
        texts = glyph_texts(r)
        if r["actual_text"]:
            out.append(r["text"])
            if not r["annotation"]:
                j += len(texts)
            continue
        # zpdf-read gives a /BaseFont that is not UTF-8 as its bytes, a list.
        zapf = isinstance(r["font"], str) and r["font"].split("+", 1)[-1] == "ZapfDingbats"
        text = []
        for t in texts:
            name, to_unicode = (None, None)
            if not r["annotation"]:
                if codes is not None:
                    name, to_unicode = codes[j]
                j += 1
            if zapf and name is None and t in zapf_names:
                name = zapf_names[t]
            if to_unicode is not None and len(to_unicode) == 1 and 8 <= ord(to_unicode) <= 13:
                t = " "
            elif to_unicode is not None and len(to_unicode) == 1 and 0xD800 <= ord(to_unicode) <= 0xDFFF:
                t = to_unicode
            elif to_unicode is not None and not (len(to_unicode) == 1 and (ord(to_unicode) < 0x20 or 0x7F <= ord(to_unicode) < 0xA0)):
                pass
            elif name is not None:
                t = mupdf_glyph_char(name)
            elif to_unicode is not None:
                t = "\ufffd"
            text.append(t)
        out.append("".join(text))
    return out


def mutool_mask_text(path, index):
    """The characters mutool draws inside soft masks on page `index` (0-based), as a multiset of
    non-white-space characters, from its trace device: a soft mask's group is run through the same
    device as the page (begin_softmask, pdf-op-run.c), and MuPDF's text device has no mask
    handler, so mask text is in mutool's page text. The trace writes a mask's content between
    <clip_mask> and </clip_mask> (trace-device.c). None when mutool fails."""
    p = subprocess.run(["mutool", "draw", "-q", "-D", "-F", "trace", "-o", "-", path, str(index + 1)], capture_output=True, timeout=300)
    if p.returncode != 0:
        return None
    depth, chars = 0, []
    for m in re.finditer(rb"<(/?)clip_mask\b|<g unicode=\"([^\"]*)\"", p.stdout):
        if m.group(1) is not None and m.group(2) is None:
            depth += -1 if m.group(1) == b"/" else 1
        elif depth > 0:
            chars.append(html.unescape(m.group(2).decode("utf-8", "replace")))
    return collections.Counter(nonwhite(as_mutool_reads("".join(chars))))


def text_explanations(path, index, runs, pm_page, mu_page, inside):
    """The deviations of MuPDF's that together leave no difference between zpdf's text and
    mutool's on a page, as their labels, or None; and the differences left after them (mutool's
    extra, zpdf's extra inside the page). Applied in turn, each only when it changes something:
    zpdf's glyphs read as MuPDF reads a code (mupdf_glyph_texts); mutool's soft-mask text taken
    out (mutool_mask_text, traced only when mutool still has more); the glyphs MuPDF's fake-bold
    rule drops (mupdf_fake_bold_drops)."""
    labels = []
    content = sum(len(r["glyphs"]) for r in runs if not r["annotation"])
    codes = pm_page["codes"] if pm_page is not None and len(pm_page["codes"]) == content else None
    texts = mupdf_glyph_texts(runs, codes)
    if texts is not None and texts != [r["text"] for r in runs]:
        labels.append("text: only where MuPDF reads a code's character its own way (glyph names, control characters, UTF-16 halves)")
    else:
        texts = [r["text"] for r in runs]

    def counted(chars):
        return collections.Counter(nonwhite(as_mutool_reads("".join(chars))))

    theirs = counted(c for c, _, _ in mu_page)
    ours, ours_inside = counted(texts), counted(t for t, r in zip(texts, runs) if inside(r))
    if theirs - ours:
        masked = theirs - (mutool_mask_text(path, index) or collections.Counter())
        if masked != theirs:
            labels.append("text: only text mutool takes from soft masks")
            theirs = masked
    missing, extra = theirs - ours, ours_inside - theirs
    if extra:
        # Only zpdf's extra characters are taken: the rule can predict a drop that mutool did
        # not make, and taking it from zpdf's text would then fail a character both have.
        dropped = extra - counted(mupdf_fake_bold_drops(runs).elements())
        if dropped != extra:
            labels.append("text: only glyphs MuPDF drops as drawn again where the previous one was")
            extra = dropped
    return (labels if not missing and not extra else None), (missing, extra)


def explained_by_tables(missing, extra):
    """Whether the text check's differences (missing: mutool has, zpdf not; extra: zpdf has,
    mutool not) are all pairs table_pairs gives: each pair is taken out of both while it fits."""
    pairs = table_pairs()
    if pairs is None:
        return False
    missing, extra = collections.Counter(missing), collections.Counter(extra)
    by_char = collections.defaultdict(list)
    for z, m in pairs:
        for c in z or m:
            by_char[c].append((z, m))
    progress = True
    while progress and (missing or extra):
        progress = False
        for c in list(extra) + list(missing):
            for z, m in by_char.get(c, ()):
                if all(extra[k] >= n for k, n in z.items()) and all(missing[k] >= n for k, n in m.items()):
                    extra -= z
                    missing -= m
                    progress = True
                    break
    return not missing and not extra


def joined_halves(a, b):
    """The character that UTF-16 halves a and b make, or None when they are not a high half then a
    low half."""
    if len(a) == 1 and len(b) == 1 and 0xD800 <= ord(a) < 0xDC00 and 0xDC00 <= ord(b) < 0xE000:
        return chr(0x10000 + ((ord(a) - 0xD800) << 10) + (ord(b) - 0xDC00))
    return None


def pdfminer_alternatives(geom, n):
    """{character: label}: what pdfminer's character n stands for once its counted deviations
    are allowed for (order_explanations): zpdf's CID-to-Unicode table's characters for its CID,
    and the character a high half makes with the low half after it."""
    out = {}
    table = geom["tables"][n]
    if table is not None:
        out[table] = ORDER_TABLES
    if n + 1 < len(geom["chars"]):
        c = joined_halves(geom["chars"][n][0], geom["chars"][n + 1][0])
        if c is not None:
            out[c] = ORDER_HALVES
    return out


ORDER_TABLES = "order: only where pdfminer's CID-to-Unicode tables are another version"
ORDER_HALVES = "order: only UTF-16 halves that pdfminer gives no character (zpdf joins a pair)"


def order_explanations(runs, geom):
    """The labels of pdfminer's deviations that account for every glyph whose characters differ
    from zpdf's, or None. Glyph by glyph (the page's content runs have pdfminer's glyphs, in
    order); ActualText glyphs left out, as in "order":
    - pdfminer reads a CID font with no /ToUnicode through its own copy of the collection's
      CID-to-Unicode table, an older version than zpdf's (src/cid): zpdf's characters must be
      what zpdf's table gives pdfminer's CID for the glyph.
    - pdfminer decodes a ToUnicode value with "ignore", so one that is a single UTF-16 half gives
      no character (pdfminer_pages keeps the half): a high half and the low half after it must
      be zpdf's character for the two glyphs, on the first, and a half alone must be U+FFFD
      (zpdf's unmapped character), on its glyph."""
    zs = [(r["actual_text"], t) for r in runs for t in glyph_texts(r)]
    chars = [c.replace("\x00", "\ufffd") for c, _, _ in geom["chars"]]
    assert len(zs) == len(chars), (len(zs), len(chars))
    labels = set()
    j = 0
    while j < len(zs):
        actual, z = zs[j]
        if actual or z == chars[j]:
            j += 1
            continue
        alternatives = pdfminer_alternatives(geom, j)
        if alternatives.get(z) == ORDER_HALVES and j + 1 < len(zs) and zs[j + 1] == (False, ""):
            labels.add(ORDER_HALVES)
            j += 2
            continue
        if len(chars[j]) == 1 and 0xD800 <= ord(chars[j]) <= 0xDFFF and z == "\ufffd":
            labels.add(ORDER_HALVES)
        elif alternatives.get(z) == ORDER_TABLES:
            labels.add(ORDER_TABLES)
        else:
            return None
        j += 1
    return sorted(labels)


def check(path, verbose):
    res = collections.Counter()
    notes = []
    z = zpdf(path)
    if "crash" in z:
        res["crash"] += 1
        notes.append(f"zpdf-read crashed ({z['crash']}): {z['stderr']}")
        return res, notes
    mu, mu_damaged = mutool_pages(path)
    pm, pm_err = pdfminer_pages(path)
    if "error" in z:
        allowed = z["error"] in ("PasswordRequired", "UnsupportedEncryption") or (z["error"] == "Malformed" and mu_damaged)
        res[f"refused {z['error']}" + (" (by design or damaged)" if allowed else " FAIL")] += 1
        return res, notes
    if pm_err:
        res["pdfminer refused"] += 1
    if mu is None:
        res["mutool refused"] += 1
    for name, other in (("mutool", mu), ("pdfminer", pm)):
        if other is not None and len(other) != len(z["pages"]):
            res[f"page count FAIL vs {name}"] += 1
            notes.append(f"pages: zpdf {len(z['pages'])}, {name} {len(other)}")
    for i, page in enumerate(z["pages"]):
        res["pages"] += 1
        if page["error"]:
            allowed = page["error"] in ("UnsupportedFont", "UnsupportedFilter")
            res[f"page refused {page['error']}" + ("" if allowed else " FAIL")] += 1
            continue
        runs = page["runs"]
        res["runs"] += len(runs)
        mu_page, clipped = mu[i] if mu is not None and i < len(mu) else (None, [])
        if mu_page is not None:
            kept = without_clip_copies(clipped, pm[i] if pm is not None and i < len(pm) else None)
            if len(kept) != len(clipped):
                res["mutool: clip-text copies left out"] += len(clipped) - len(kept)
            mu_page = mu_page + kept
        if mu_page is not None and pm is not None and i < len(pm) and pm[i]["unsigned_signatures"] and page["rotate"] == 0:
            n = len(mu_page)
            mu_page = without_signature_labels(mu_page, pm[i]["unsigned_signatures"], page["crop_box"])
            if n != len(mu_page):
                res["mutool: MuPDF's SIGN labels left out"] += (n - len(mu_page)) // 4
        geom = pm[i] if pm is not None and i < len(pm) else None
        if geom is not None:
            same_box = all(abs(a - b) < 1e-6 for a, b in zip(geom["media_box"], page["media_box"]))
            if not same_box or geom["rotate"] != page["rotate"]:
                res["box FAIL"] += 1
                notes.append(f"p{i} box: zpdf {page['media_box']} rotate {page['rotate']}, pdfminer {geom['media_box']} rotate {geom['rotate']}")
                geom = None

        cx0, cy0, cx1, cy1 = page["crop_box"]

        def inside(r):
            # A vertical run goes down the page from its first glyph; a horizontal one, right.
            w = r["width"] or 0
            x_end, y_end = (r["x"], r["y"] - w) if r["vertical"] else (r["x"] + w, r["y"])
            xs, ys = sorted((r["x"], x_end)), sorted((r["y"], y_end))
            return cx0 + r["size"] <= xs[0] and xs[1] <= cx1 - r["size"] and cy0 + r["size"] <= ys[0] and ys[1] <= cy1 - r["size"]

        # mutool's characters by (character, cell) on a TOL grid, for the glyph check's vote.
        mu_cells = None
        if mu_page is not None and page["rotate"] == 0:
            mu_cells = collections.defaultdict(list)
            for c, cx, cy in mu_page:
                mu_cells[(c, round(cx / TOL), round(cy / TOL))].append((cx, cy))

        def mutool_has(c, g, r):
            """Whether mutool has character c within TOL of glyph g's origin (r's glyph)."""
            if mu_cells is None or not c or not inside(r):
                return False
            x, y = g["x"] - cx0, cy1 - g["y"]
            bx, by = round(x / TOL), round(y / TOL)
            return any(abs(cx - x) < TOL and abs(cy - y) < TOL
                       for dx in (-1, 0, 1) for dy in (-1, 0, 1) for cx, cy in mu_cells.get((c, bx + dx, by + dy), ()))

        if mu_page is not None:
            theirs = collections.Counter(nonwhite("".join(c for c, _, _ in mu_page)))
            all_ours = collections.Counter(nonwhite(as_mutool_reads("".join(r["text"] for r in runs))))
            ours_inside = collections.Counter(nonwhite(as_mutool_reads("".join(r["text"] for r in runs if inside(r)))))
            missing, extra = theirs - all_ours, ours_inside - theirs
            if not missing and not extra:
                res["text ok"] += 1
            elif explained_by_tables(missing, extra):
                res["text: only where MuPDF's CID-to-Unicode tables are another version"] += 1
            elif not missing and set(extra) == {"\ufffd"}:
                # A Type0 font's code with no CID mapping draws CID 0's glyph (ISO 32000-1
                # 9.7.6.3), which zpdf gives as U+FFFD; MuPDF drops the code (pdf_show_string).
                res["text: only U+FFFD more than mutool (codes with no CID mapping)"] += 1
            else:
                labels, left = text_explanations(path, i, runs, pm[i] if pm is not None and i < len(pm) else None, mu_page, inside)
                if labels is not None:
                    for label in labels:
                        res[label] += 1
                else:
                    res["text FAIL"] += 1
                    if verbose:
                        notes.append(f"p{i} text: mutool has, zpdf not {dict(list(missing.items())[:8])}; zpdf has inside the page, mutool not {dict(list(extra.items())[:8])}")
                        notes.append(f"p{i} text, after every explanation: mutool has, zpdf not {dict(list(left[0].items())[:8])}; zpdf has, mutool not {dict(list(left[1].items())[:8])}")

        # mutool's vote takes MuPDF's character for the run's first glyph too (mupdf_glyph_texts):
        # the vote is on where the run starts, and MuPDF can read that glyph's code as another
        # character.
        content = sum(len(r["glyphs"]) for r in runs if not r["annotation"])
        pm_codes = pm[i]["codes"] if pm is not None and i < len(pm) and len(pm[i]["codes"]) == content else None
        mupdf_texts = mupdf_glyph_texts(runs, pm_codes) if mu_page is not None else None
        for k, r in enumerate(runs):
            t = r["text"]
            if not t or t[0] == "�" or t[0].isspace():
                continue
            if r["actual_text"]:
                res["start skipped: ActualText"] += 1
                continue
            votes = {}
            if mu_page is not None and page["rotate"] == 0 and inside(r):
                x, y = r["x"] - cx0, cy1 - r["y"]
                first = {t[0], as_mutool_reads(mupdf_texts[k][:1])} if mupdf_texts and mupdf_texts[k] else {t[0]}
                votes["mutool"] = any(c in first and abs(cx - x) < TOL and abs(cy - y) < TOL for c, cx, cy in mu_page)
            if geom is not None and not r["annotation"]:
                # A pdfminer character also votes for what it stands for once its counted
                # deviations are allowed for (pdfminer_alternatives), and that is counted.
                exact = allowed = False
                for n, (c, m, _) in enumerate(geom["chars"]):
                    u = pdfminer_to_user(geom, (m[4], m[5]))
                    if abs(u[0] - r["x"]) >= TOL or abs(u[1] - r["y"]) >= TOL:
                        continue
                    if c[:1] == t[0]:
                        exact = True
                        break
                    allowed = allowed or any(a[:1] == t[0] for a in pdfminer_alternatives(geom, n))
                votes["pdfminer"] = exact or allowed
                if allowed and not exact:
                    res["start: pdfminer agrees once its CID tables or UTF-16 halves are allowed for"] += 1
            if not votes:
                continue
            if all(votes.values()):
                res["start ok"] += 1
            elif any(votes.values()):
                res["start: only " + next(k for k, v in votes.items() if v) + " agrees"] += 1
            else:
                res["start FAIL"] += 1
                if verbose and res["start FAIL"] <= 3:
                    notes.append(f"p{i} start: run {t[:20]!r} at ({r['x']:.3f}, {r['y']:.3f}) matches no oracle")

        if geom is None:
            continue
        chars = geom["chars"]
        # pdfminer reads the page's content stream only, never an annotation's appearance.
        runs = [r for r in runs if not r["annotation"]]
        glyphs = [g for r in runs for g in r["glyphs"]]
        if len(glyphs) != len(chars):
            # pdfminer drops a code with no CID mapping (its CMap.decode yields nothing), where
            # zpdf draws CID 0 (9.7.6.3) as U+FFFD: counted when zpdf's extra glyphs are exactly
            # its U+FFFD glyphs beyond pdfminer's. The page's positions are then not compared.
            ours_fffd = sum(1 for r in runs if not r["actual_text"] for t in glyph_texts(r) if t[:1] == "\ufffd")
            theirs_fffd = sum(1 for c, _, _ in chars if c == "\ufffd")
            if len(glyphs) > len(chars) and len(glyphs) - len(chars) == ours_fffd - theirs_fffd:
                res["glyph count: pdfminer drops codes with no CID mapping (page not compared)"] += 1
                continue
            res["glyph count FAIL"] += 1
            if verbose:
                notes.append(f"p{i} glyphs: zpdf {len(glyphs)}, pdfminer {len(chars)}")
            continue
        # Every glyph's origin. After a gap in pdfminer's widths, the rest of the run must be
        # off by one constant shift (the missing width), which is counted, not failed.
        bad = []
        shifted = 0
        k = 0
        actual_glyphs = set()
        for r in runs:
            gap, shift = False, None
            texts = glyph_texts(r)
            for j in range(k, k + len(r["glyphs"])):
                if r["actual_text"]:
                    actual_glyphs.add(j)
                c, m, adv = chars[j]
                g = glyphs[j]
                u = pdfminer_to_user(geom, (m[4], m[5]))
                d = (g["x"] - u[0], g["y"] - u[1])
                if abs(d[0]) >= TOL or abs(d[1]) >= TOL:
                    if gap and (shift is None or (abs(d[0] - shift[0]) < TOL and abs(d[1] - shift[1]) < TOL)):
                        shift = d
                        shifted += 1
                    else:
                        bad.append((g, u, r, as_mutool_reads(texts[j - k])[:1]))
                if zero_width_gap(c, adv):
                    gap, shift = True, None
            k += len(r["glyphs"])
        # A glyph pdfminer places elsewhere is still right when mutool has its character at the
        # glyph's origin: pdfminer, not zpdf, is then the one that differs. Like "start", it
        # fails only when every oracle that can measure it disagrees; an ActualText glyph, or one
        # mutool cannot measure, fails.
        mutool_agrees = [b for b in bad if not b[2]["actual_text"] and mutool_has(b[3], b[0], b[2])]
        bad = [b for b in bad if b[2]["actual_text"] or not mutool_has(b[3], b[0], b[2])]
        if shifted:
            res["glyphs shifted by a pdfminer width gap"] += shifted
        if mutool_agrees:
            res["glyphs: only mutool agrees"] += len(mutool_agrees)
        res["glyphs ok"] += len(glyphs) - len(bad) - shifted - len(mutool_agrees)
        if bad:
            res["glyphs FAIL"] += len(bad)
            if verbose:
                g, u = bad[0][:2]
                notes.append(f"p{i} glyph at ({g['x']:.3f}, {g['y']:.3f}); pdfminer ({u[0]:.3f}, {u[1]:.3f}); {len(bad)} differ")
        # The text in order, white space included; ActualText glyphs left out on both sides.
        ours = "".join(r["text"] for r in runs if not r["actual_text"])
        # pdfminer gives a ToUnicode destination of U+0000 as it is; zpdf reads it as no
        # character (U+FFFD, counted unmapped), as producers mean it.
        theirs = "".join(c for j, (c, _, _) in enumerate(chars) if j not in actual_glyphs).replace("\x00", "\ufffd")
        order_labels = None if ours == theirs else order_explanations(runs, geom)
        if ours == theirs:
            res["order ok"] += 1
        elif order_labels is not None:
            for label in order_labels:
                res[label] += 1
        else:
            res["order FAIL"] += 1
            if verbose:
                at = next((j for j in range(min(len(ours), len(theirs))) if ours[j] != theirs[j]), min(len(ours), len(theirs)))
                notes.append(f"p{i} order: differ at {at}: zpdf {ours[at:at + 20]!r} pdfminer {theirs[at:at + 20]!r}")
    return res, notes


def main():
    args = [a for a in sys.argv[1:] if a != "--verbose"]
    verbose = "--verbose" in sys.argv
    files = []
    for a in args:
        p = pathlib.Path(a)
        files += sorted(p.rglob("*.pdf")) if p.is_dir() else [p]
    total = collections.Counter()
    failed = 0
    for f in files:
        if not f.is_file():
            print(f"skip {f}: no such file")
            continue
        res, notes = check(str(f), verbose)
        total += res
        bad = {k: v for k, v in res.items() if "FAIL" in k or k == "crash"}
        failed += bool(bad)
        print(f"{'FAIL' if bad else 'ok  '} {f}: " + ", ".join(f"{k} {v}" for k, v in sorted(res.items())))
        for n in notes:
            print(f"     {n}")
    print(f"\n{len(files)} files, {failed} with a failed check")
    for k, v in sorted(total.items()):
        print(f"  {k}: {v}")
    sys.exit(1 if failed else 0)


main()
