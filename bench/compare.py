# /// script
# requires-python = ">=3.11"
# dependencies = ["pymupdf==1.28.2"]
# ///
"""Time zpdf-text against three other shape-and-write-PDF stacks on the same text and font.

    uv run bench/compare.py [--runs N] [--out DIR]

Run from the repo root after `zig build` has fetched the harfbuzz package (the fonts come from
it). Needs `zig`, `hb-view`, `mutool` and `qpdf` on PATH. Prints one table; raw timings go to
DIR/results.json (default: a new temp dir, printed at the end).

The four tools, each run as one process per PDF:

- zpdf     zpdf-text, built here with -Doptimize=ReleaseFast: kb shaping, the zpdf writer.
- hb-view  `hb-view -O pdf`: HarfBuzz shaping, Cairo's PDF writer.
- pymupdf  PyMuPDF `insert_htmlbox` + `subset_fonts`: HarfBuzz shaping inside MuPDF's HTML
           layout, MuPDF's writer. Its process time includes starting Python and importing
           pymupdf, and its layout does more than place lines.
- mutool   `mutool convert` of the same HTML and CSS: the same MuPDF layout and writer from C,
           with no Python. The HTML is written before timing. mutool has no font subsetting,
           so its files embed whole fonts; compare its size on `qpdf KB` with that in mind.

Process start-up differs a lot between the four, so the table gives two numbers per tool:
`tiny` (one short line, which is about start-up and font loading) and `per 1k cp` (the
extra milliseconds per 1,000 codepoints between the small and large inputs, which is the
shaping and writing cost without start-up). Compare tools on `per 1k cp`. `qpdf KB` is each
output recompressed by qpdf with object streams, so sizes compare the content, not each
tool's compression level and file structure.

Validity. These stop the run, because a tool that fails them did not do the work:
- the process exits 0 and writes a non-empty file;
- `mutool trace` finds drawn glyphs on as many lines as the input has.

Shaping agreement is reported, not fatal, because two correct shapers can differ: a line counts
as different from zpdf unless it has the same number of drawn glyphs and the gaps between its
sorted glyph x positions agree within GAP_TOLERANCE_PT. Every differing input is printed as
SHAPING DIFFERS. Glyph ids are not compared, because Cairo renumbers them when it subsets. A
tool that skipped shaping, dropped a glyph or wrapped a line shows up there. For pymupdf and
mutool only, a gap next to a space may differ, because MuPDF's layout does not kern across a
space; the table counts them.
"""

import argparse
import html
import json
import os
import random
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

FONT_SIZE = 12.0

# Words are joined until a line reaches LINE_CP codepoints. Each sample exercises the
# script's shaping: ligatures and kerning, conjuncts and reordered vowel signs, joining
# forms and lam-alef, and Hebrew with niqqud. The words are picked in a seeded random order,
# so no two lines are the same text: zpdf keeps each font's shaped lines by their text
# (src/pdf.zig, EmbeddedFont.shapes), so repeated lines would cost it almost nothing, and
# no other tool here keeps one. make_lines refuses a repeated line.
SCRIPTS = {
    "latin": ("Roboto-Regular.ttf", "office affine AVATAR Tolkien waffle The quick brown fox jumps over"),
    "devanagari": ("NotoSansDevanagari-Regular.ttf", "हिन्दी भाषा में किसी क्षेत्र की स्थिति कि क्ष त्र श्र"),
    "arabic": ("Amiri-Regular.ttf", "بسم الله الرحمن الرحيم لا مرحبا بالعالم العربية"),
    "hebrew": ("NotoIKEAHebrewLatin-Regular.ttf", "שָׁלוֹם עולם זהו מבחן של כתיבה בעברית"),
}
LINE_CP = 60
SIZES = {"tiny": 1, "small": 200, "large": 2000}


def make_lines(sample: str, n_lines: int, tiny: bool) -> list[str]:
    words = sample.split()
    if tiny:
        return [words[0]]
    rng = random.Random(n_lines)
    lines = []
    for _ in range(n_lines):
        line = ""
        while len(line) < LINE_CP:
            line = (line + " " + rng.choice(words)).strip()
        lines.append(line)
    if len(set(lines)) != len(lines):
        sys.exit(f"bench: {len(lines) - len(set(lines))} repeated lines; a repeated line is shaped from zpdf's cache")
    return lines


def fonts_dir(repo: Path) -> Path:
    # Read the package hash from build.zig.zon rather than rebuilding it.
    zon = (repo / "build.zig.zon").read_text()
    m = re.search(r"\.harfbuzz\s*=\s*\.\{[^}]*\.hash\s*=\s*\"([^\"]+)\"", zon, re.S)
    if not m:
        sys.exit("bench: no harfbuzz hash in build.zig.zon")
    d = repo / "zig-pkg" / m.group(1) / "test" / "subset" / "data" / "fonts"
    if not d.is_dir():
        sys.exit(f"bench: {d} is missing; run `zig build` once to fetch it")
    return d


# MuPDF's HTML layout, for pymupdf and mutool. Wide and tall enough that no line wraps and
# nothing is scaled down; the font file sits next to the HTML.
PAGE_WIDTH = 4000


def page_height(n_lines: int) -> float:
    return 200 + n_lines * FONT_SIZE * 3


def mupdf_css(font: str) -> str:
    return (
        "@font-face {font-family: F; src: url(%s);} "
        "* {font-family: F; font-size: %gpt; line-height: 1.5; margin: 0;}"
    ) % (os.path.basename(font), FONT_SIZE)


def mupdf_body(lines: list[str]) -> str:
    return "".join("<p dir='auto'>%s</p>" % html.escape(l) for l in lines)


def write_mutool_html(font: str, lines: list[str], path: Path) -> None:
    """The input `mutool convert` lays out: the same CSS and paragraphs as write_pymupdf."""
    copy = path.parent / os.path.basename(font)
    if not copy.exists():
        copy.write_bytes(Path(font).read_bytes())
    path.write_text("<html><head><meta charset='utf-8'><style>%s</style></head><body>%s</body></html>"
                    % (mupdf_css(font), mupdf_body(lines)), encoding="utf-8")


def write_pymupdf(font: str, out: str, lines_file: str) -> None:
    import pymupdf

    lines = Path(lines_file).read_text(encoding="utf-8").splitlines()
    doc = pymupdf.open()
    page = doc.new_page(width=PAGE_WIDTH, height=page_height(len(lines)))
    css = mupdf_css(font)
    body = mupdf_body(lines)
    spare, _ = page.insert_htmlbox(
        page.rect + (20, 20, -20, -20), body, css=css,
        archive=pymupdf.Archive(os.path.dirname(font)), scale_low=1,
    )
    if spare < 0:
        sys.exit("pymupdf: text did not fit")
    doc.subset_fonts()
    doc.save(out, garbage=3, deflate=True)


def commands(tool, exe, font, lines_file, out, html_file, n_lines):
    if tool == "zpdf":
        return [exe, font, f"--size={FONT_SIZE:g}", f"--out={out}", f"--text-file={lines_file}"]
    if tool == "hb-view":
        return ["hb-view", "-O", "pdf", f"--font-size={FONT_SIZE:g}", f"--text-file={lines_file}", "-o", out, font]
    if tool == "pymupdf":
        return [sys.executable, __file__, "write-pymupdf", font, out, lines_file]
    if tool == "mutool":
        return ["mutool", "convert", "-W", str(PAGE_WIDTH), "-H", f"{page_height(n_lines):g}",
                "-O", "compress", "-o", out, html_file]
    raise ValueError(tool)


# Only entries with a glyph attribute are drawn glyphs. A ligature's extra characters show up as
# glyph-less entries, and the tools differ in whether they write them.
G_RE = re.compile(r'<g unicode="([^"]*)" glyph="[^"]*" x="([^"]+)" y="([^"]+)"')
# The writers round positions differently (Cairo and MuPDF to about 0.01 pt). A missing kerning
# pair or mark offset moves a glyph by more than this at 12 pt.
GAP_TOLERANCE_PT = 0.03


def line_shapes(pdf: str) -> list[tuple[list[float], list[bool]]]:
    """Per line, in the order the lines first appear: the gaps between sorted glyph x positions,
    and which of the sorted glyphs map to a space. Cairo's unicode mapping is shifted, so the space
    flags are only read from tools whose mapping is right."""
    trace = subprocess.run(["mutool", "trace", pdf], capture_output=True, text=True, check=True).stdout
    by_y: dict[str, list[tuple[float, bool]]] = {}
    for u, x, y in G_RE.findall(trace):
        by_y.setdefault(y, []).append((float(x), u == " "))
    shapes = []
    for glyphs in by_y.values():
        glyphs.sort()
        xs = [x for x, _ in glyphs]
        shapes.append(([b - a for a, b in zip(xs, xs[1:])], [sp for _, sp in glyphs]))
    return shapes


def compare_line(got, want, skip_space_gaps: bool) -> tuple[bool, int]:
    """(matches, gaps next to a space that differ). With skip_space_gaps those gaps do not fail
    the match: MuPDF's HTML layout drops kerning between a space and the next glyph, which
    zpdf and HarfBuzz apply."""
    gaps, spaces = got
    want_gaps, _ = want
    if len(gaps) != len(want_gaps):
        return False, 0
    space_diffs = 0
    for i, (a, b) in enumerate(zip(gaps, want_gaps)):
        if abs(a - b) <= GAP_TOLERANCE_PT:
            continue
        if skip_space_gaps and (spaces[i] or spaces[i + 1]):
            space_diffs += 1
            continue
        return False, space_diffs
    return True, space_diffs


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "write-pymupdf":
        write_pymupdf(*sys.argv[2:5])
        return

    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()
    if args.runs < 3:
        sys.exit("bench: --runs must be at least 3")

    repo = Path(__file__).resolve().parent.parent
    out = args.out or Path(tempfile.mkdtemp(prefix="zpdf-bench-"))
    out.mkdir(parents=True, exist_ok=True)
    fonts = fonts_dir(repo)

    prefix = out / "prefix"
    # tools/zig: the zig this checkout builds with (zig on PATH can be another version).
    subprocess.run([str(repo / "tools" / "zig"), "build", "-Doptimize=ReleaseFast", "--prefix", str(prefix)], cwd=repo, check=True)
    exe = str(prefix / "bin" / "zpdf-text")

    tools = ["zpdf", "hb-view", "pymupdf", "mutool"]
    html_dir = out / "html"
    html_dir.mkdir(exist_ok=True)
    results = []
    warnings = []
    for script, (font_name, sample) in SCRIPTS.items():
        font = str(fonts / font_name)
        for size_name, n_lines in SIZES.items():
            lines = make_lines(sample, n_lines, size_name == "tiny")
            n_cp = sum(len(l) for l in lines)
            lines_file = out / f"{script}-{size_name}.txt"
            lines_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
            html_file = html_dir / f"{script}-{size_name}.html"
            write_mutool_html(font, lines, html_file)
            shapes = {}
            for tool in tools:
                pdf = str(out / f"{script}-{size_name}-{tool}.pdf")
                cmd = commands(tool, exe, font, str(lines_file), pdf, str(html_file), len(lines))
                times = []
                for run in range(args.runs + 1):
                    if os.path.exists(pdf):
                        os.remove(pdf)
                    t0 = time.perf_counter()
                    p = subprocess.run(cmd, capture_output=True, text=True)
                    t1 = time.perf_counter()
                    if p.returncode != 0 or not os.path.exists(pdf) or os.path.getsize(pdf) == 0:
                        sys.exit(f"bench: {tool} {script}-{size_name} failed: rc={p.returncode} {p.stderr[:300]}")
                    if run > 0:  # run 0 warms the file cache
                        times.append((t1 - t0) * 1000)
                s = line_shapes(pdf)
                if len(s) != len(lines):
                    sys.exit(f"bench: {tool} {script}-{size_name}: {len(s)} glyph lines, expected {len(lines)}")
                shapes[tool] = s
                # Each tool compresses at its own level and only some use object streams.
                # Recompressing every output with one tool puts them on one footing.
                packed = pdf + ".qpdf"
                subprocess.run(["qpdf", "--compress-streams=y", "--recompress-flate", "--object-streams=generate",
                                pdf, packed], check=True)
                results.append({
                    "script": script, "size": size_name, "tool": tool, "codepoints": n_cp,
                    "glyphs": sum(len(g) + 1 for g, _ in s), "bytes": os.path.getsize(pdf), "qpdf_bytes": os.path.getsize(packed),
                    "ms": times,
                })
            for tool in tools[1:]:
                bad, space_diffs = 0, 0
                for got, want in zip(shapes[tool], shapes["zpdf"]):
                    ok, n = compare_line(got, want, skip_space_gaps=tool in ("pymupdf", "mutool"))
                    bad += not ok
                    space_diffs += n
                row = next(r for r in results if (r["script"], r["size"], r["tool"]) == (script, size_name, tool))
                row["space_gaps_differ"] = space_diffs
                row["lines_differ"] = bad
                if bad:
                    warnings.append(f"{script}-{size_name}: {tool} shapes {bad} of {len(lines)} lines differently from zpdf")

    (out / "results.json").write_text(json.dumps(results, indent=1))

    def med(script, size, tool):
        r = next(r for r in results if (r["script"], r["size"], r["tool"]) == (script, size, tool))
        return statistics.median(r["ms"]), r

    print(f"\nwall ms, median of {args.runs}; per 1k cp = (large - small) / extra codepoints")
    print(f"{'script':<11}{'tool':<9}{'tiny ms':>9}{'small ms':>10}{'large ms':>10}{'per 1k cp':>11}{'large KB':>10}{'qpdf KB':>9}{'spread':>9}{'space gaps':>12}{'lines != zpdf':>15}")
    for script in SCRIPTS:
        for tool in tools:
            t_tiny, _ = med(script, "tiny", tool)
            t_small, r_small = med(script, "small", tool)
            t_large, r_large = med(script, "large", tool)
            per_k = (t_large - t_small) / (r_large["codepoints"] - r_small["codepoints"]) * 1000
            spread = (max(r_large["ms"]) - min(r_large["ms"])) / t_large * 100
            print(f"{script:<11}{tool:<9}{t_tiny:>9.1f}{t_small:>10.1f}{t_large:>10.1f}{per_k:>11.2f}"
                  f"{r_large['bytes'] / 1024:>10.1f}{r_large['qpdf_bytes'] / 1024:>9.1f}{spread:>8.0f}%{r_large.get('space_gaps_differ', 0):>12}"
                  f"{r_large.get('lines_differ', 0):>15}")
    print(f"\n'space gaps' and 'lines != zpdf' are for the large input. Glyph gaps agree within"
          f" {GAP_TOLERANCE_PT} pt unless a line is counted in 'lines != zpdf'.")
    for w in warnings:
        print("SHAPING DIFFERS:", w)
    print(f"raw: {out / 'results.json'}")


if __name__ == "__main__":
    main()
