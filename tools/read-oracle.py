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
  0.02 pt. This checks advances, Tc, Tw, Tz and TJ adjustments glyph by glyph.
- "order", against pdfminer: the characters of the runs, white space included, must be
  pdfminer's, in order. The glyphs of ActualText runs are left out on both sides (pdfminer
  ignores ActualText; mutool's "text" checks those).
- Annotation runs (the text of appearance streams, after the page's) are checked against mutool
  only: pdfminer reads no annotation, so "glyphs", "order" and its "start" vote leave them out.

Where an oracle deviates from ISO 32000-1, the deviation is undone or counted, never silently
excused; each one is in the code beside the place it applies:
- pdfminer leaves out the character spacing after an operator's last glyph and the text rise in
  a glyph's origin (both undone in pdfminer_pages), and has no Euro width for Helvetica (the
  glyphs after such a gap must then be off by one constant shift, which is counted).
- mutool splits ligature characters unless asked not to (preserve-ligatures).
- mutool draw leaves out text that the clip hides completely (FZ_STEXT_CLIP, set by mudraw.c
  unless clip=no). zpdf gives all the text a page draws, so mutool is asked for it too (clip=no).
- mutool draw -F stext collects styles (FZ_STEXT_COLLECT_STYLES, set by mudraw.c for every text
  format but txt). With it, a glyph drawn twice at one place is given once (taken as fake bold),
  and the text MuPDF places on an image for an ActualText span with no glyph
  (fz_stext_end_metatext) is missing from the output, though txt has it. zpdf gives both, so
  mutool is asked without styles (collect-styles=no).
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
import json
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
    """(pages of (char, x, y) in device space, whether mutool reported damage), or (None, ...)
    when mutool cannot read the file."""
    # preserve-ligatures: mutool otherwise splits U+FB03 into "ffi", which is not what the file says.
    # clip=no: mutool otherwise leaves out text the clip hides; zpdf gives all the text drawn.
    # collect-styles=no: mutool otherwise drops a glyph drawn twice, and an image's ActualText.
    p = subprocess.run(["mutool", "draw", "-q", "-F", "stext", "-O", "preserve-ligatures,clip=no,collect-styles=no", "-o", "-", path], capture_output=True, timeout=120)
    damaged = b"repair" in p.stderr or b"broken" in p.stderr
    if p.returncode != 0:
        return None, damaged
    root = ET.fromstring(xml_safe(p.stdout.decode("utf-8", "replace")))
    pages = []
    for page in root.iter("page"):
        chars = []
        for ch in page.iter("char"):
            c = ch.get("c")
            if c is not None:
                chars.append((c, float(ch.get("x")), float(ch.get("y"))))
        pages.append(chars)
    return pages, damaged


def pdfminer_pages(path):
    """(pages of {"media_box", "rotate", "chars": [(text, origin matrix, advance)]}, error)."""
    # Not high_level.extract_pages: it replaces laparams=None with LAParams(), whose layout
    # analysis reorders characters. The aggregator with no laparams keeps content order.
    from pdfminer.converter import PDFPageAggregator
    from pdfminer.layout import LTChar
    from pdfminer.pdfdevice import PDFTextDevice
    from pdfminer.pdfinterp import PDFPageInterpreter, PDFResourceManager
    from pdfminer.pdfpage import PDFPage

    # pdfminer adds the character spacing (Tc) before every glyph but an operator's first, so the
    # Tc after an operator's last glyph is never added (pdfdevice.render_string_horizontal,
    # needcharspace), and its pen falls behind by Tc at each operator until the next Td. ISO
    # 32000-1 9.4.4 adds Tc after every glyph; mutool does, and so does zpdf. Add the missing one.
    if not hasattr(PDFTextDevice, "_zpdf_tc"):
        horizontal = PDFTextDevice.render_string_horizontal

        def with_last_tc(self, seq, matrix, pos, font, fontsize, scaling, charspace, *rest):
            x, y = horizontal(self, seq, matrix, pos, font, fontsize, scaling, charspace, *rest)
            if any(isinstance(o, bytes) and font.decode(o) for o in seq):
                x += charspace
            return (x, y)

        PDFTextDevice.render_string_horizontal = with_last_tc
        PDFTextDevice._zpdf_tc = True

    # LTChar keeps the text rise only inside its bounding box; keep it, so a glyph's origin can
    # include it as zpdf's does (ISO 32000-1 9.4.4: the origin is (0, Ts) in text space).
    if not hasattr(LTChar, "_zpdf_rise"):
        init = LTChar.__init__

        def keep_rise(self, matrix, font, fontsize, scaling, rise, *rest):
            init(self, matrix, font, fontsize, scaling, rise, *rest)
            self._zpdf_rise = rise

        LTChar.__init__ = keep_rise
        LTChar._zpdf_rise = 0

    def walk(item, out):
        if isinstance(item, LTChar):
            text = item.get_text()
            a, b, c, d, e, f = item.matrix
            r = item._zpdf_rise
            origin = (a, b, c, d, e + c * r, f + d * r)
            out.append((re.sub(r"\(cid:\d+\)", "�", text), origin, item.adv))
        elif hasattr(item, "__iter__"):
            for child in item:
                walk(child, out)

    pages = []
    try:
        rsrc = PDFResourceManager()
        device = PDFPageAggregator(rsrc, laparams=None)
        interp = PDFPageInterpreter(rsrc, device)
        with open(path, "rb") as f:
            for page in PDFPage.get_pages(f):
                interp.process_page(page)
                out = []
                walk(device.get_result(), out)
                pages.append({"media_box": [float(v) for v in page.mediabox], "rotate": page.rotate % 360, "chars": out})
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
        ours = ucs2_table((pathlib.Path(__file__).resolve().parent.parent / "src/cid" / name).read_text(encoding="latin-1"))
        theirs = ucs2_table(theirs_path.read_text(encoding="latin-1"))
        for cid in ours.keys() | theirs.keys():
            a, b = ours.get(cid, "\ufffd"), theirs.get(cid, "\ufffd")
            if nonwhite(a) != nonwhite(b):
                pairs.add((nonwhite(a), nonwhite(b)))
    # Each pair as what it adds on each side: 通 + U+E0100 against 通 is one more U+E0100 in zpdf.
    reduced = {(frozenset((collections.Counter(a) - collections.Counter(b)).items()), frozenset((collections.Counter(b) - collections.Counter(a)).items())) for a, b in pairs}
    return [(collections.Counter(dict(z)), collections.Counter(dict(m))) for z, m in reduced if z or m]


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
        mu_page = mu[i] if mu is not None and i < len(mu) else None
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
                res["text FAIL"] += 1
                if verbose:
                    notes.append(f"p{i} text: mutool has, zpdf not {dict(list(missing.items())[:8])}; zpdf has inside the page, mutool not {dict(list(extra.items())[:8])}")

        for r in runs:
            t = r["text"]
            if not t or t[0] == "�" or t[0].isspace():
                continue
            if r["actual_text"]:
                res["start skipped: ActualText"] += 1
                continue
            votes = {}
            if mu_page is not None and page["rotate"] == 0 and inside(r):
                x, y = r["x"] - cx0, cy1 - r["y"]
                votes["mutool"] = any(c == t[0] and abs(cx - x) < TOL and abs(cy - y) < TOL for c, cx, cy in mu_page)
            if geom is not None and not r["annotation"]:
                votes["pdfminer"] = any(c[:1] == t[0] and abs(u[0] - r["x"]) < TOL and abs(u[1] - r["y"]) < TOL for c, m, _ in geom["chars"] for u in [pdfminer_to_user(geom, (m[4], m[5]))])
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
            ours_fffd = sum(1 for r in runs if not r["actual_text"] for g in r["glyphs"] if r["text"][g["text_at"] : g["text_at"] + 1] == "\ufffd")
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
                        bad.append((g, u))
                if zero_width_gap(c, adv):
                    gap, shift = True, None
            k += len(r["glyphs"])
        if shifted:
            res["glyphs shifted by a pdfminer width gap"] += shifted
        res["glyphs ok"] += len(glyphs) - len(bad) - shifted
        if bad:
            res["glyphs FAIL"] += len(bad)
            if verbose:
                g, u = bad[0]
                notes.append(f"p{i} glyph at ({g['x']:.3f}, {g['y']:.3f}); pdfminer ({u[0]:.3f}, {u[1]:.3f}); {len(bad)} differ")
        # The text in order, white space included; ActualText glyphs left out on both sides.
        ours = "".join(r["text"] for r in runs if not r["actual_text"])
        theirs = "".join(c for j, (c, _, _) in enumerate(chars) if j not in actual_glyphs)
        if ours == theirs:
            res["order ok"] += 1
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
