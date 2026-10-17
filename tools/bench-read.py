# /// script
# requires-python = ">=3.11"
# ///
"""Time zpdf.read against its own base (regressions) and against MuPDF and Poppler, on the same PDFs.

    uv run tools/bench-read.py [--base main] [--runs 5] [--scenario grid:20000] [--pdf file.pdf ...]
                               [--changed-output]

The corpus is written first, by the writers tools/bench-ab.py times: the same pages (its scenarios)
from zpdf (Type 0, embedded and compressed), MuPDF and Cairo. Three producers, one text, so every
reader must extract the same characters from every file. --pdf adds files of your own.

Readers, each run as a process with its output discarded, so start-up and the whole file are counted:
- zpdf: zpdf-read from this tree, ReleaseFast. Its output is JSON with every run and every glyph.
- zpdf-safe: the same, ReleaseSafe, the mode libzpdf ships in (build.zig, addNative).
- zpdf-base: zpdf-read from --base, ReleaseFast.
- mutool: mutool draw -F txt (MuPDF's text extraction, as plain text). Not -F stext: writing
  every character's box as XML took about 85% of mutool's time on a 445-page file (2028 ms
  against 302 ms for txt, 2026-10-16), so it timed the output format, not the reading.
- pdftotext: Poppler's pdftotext -bbox (every word with its box, HTML).
The readers do not do the same work: zpdf-read writes every glyph's position as JSON; mutool
groups characters into lines and blocks; pdftotext lays out words with their boxes. So compare zpdf with zpdf-base for
regressions, and read the others as the scale of a known tool on the same file.

Before timing, each file is checked once: every reader must exit 0, zpdf and zpdf-safe (the same
tree) must print the same JSON, and so must zpdf-base, unless --changed-output says this tree is
meant to read something else (then a difference is printed, not refused). The non-white-space
characters zpdf-read and mutool read must be the same multiset. On the written corpus a difference
fails; on --pdf files it is printed (mutool and zpdf.read differ by design on some files:
tools/read-oracle.py lists how). A reader that read nothing fails, so it cannot look fast.

Exit status 1 when zpdf is slower than zpdf-base on a file both read the same, and the two sets of
runs do not overlap,
twice: a first gap is re-run with three times the runs, and only a gap that stays counts.
Nothing is stored. Needs what tools/bench-ab.py needs, and Poppler (pdftotext).
"""

import argparse
import collections
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
# bench-ab.py is loaded as a module; no __pycache__ beside it.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("bench_ab", REPO / "tools/bench-ab.py")
ab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ab)
run = ab.run


def build_readers(work: Path, base: str):
    new = work / "zpdf-new"
    safe = work / "zpdf-safe"
    run([ab.ZIG, "build", "-Doptimize=ReleaseFast", "--prefix", str(new)], cwd=REPO)
    run([ab.ZIG, "build", "-Doptimize=ReleaseSafe", "--prefix", str(safe)], cwd=REPO)
    tree = work / "base-tree"
    run(["git", "worktree", "add", "--detach", str(tree), base], cwd=REPO)
    old = work / "zpdf-base"
    try:
        if not (tree / "src/zpdf-read.zig").exists():
            sys.exit(f"bench-read: {base} has no zpdf-read")
        # The base fetches the same packages; reuse this tree's copies.
        (tree / "zig-pkg").symlink_to(REPO / "zig-pkg")
        run([ab.ZIG, "build", "-Doptimize=ReleaseFast", "--prefix", str(old)], cwd=tree)
    finally:
        run(["git", "worktree", "remove", "--force", str(tree)], cwd=REPO)
    return {"zpdf": new / "bin/zpdf-read", "zpdf-safe": safe / "bin/zpdf-read", "zpdf-base": old / "bin/zpdf-read"}


def reader_commands(readers, pdf: Path):
    return {
        "zpdf": [readers["zpdf"], pdf],
        "zpdf-safe": [readers["zpdf-safe"], pdf],
        "zpdf-base": [readers["zpdf-base"], pdf],
        "mutool": ["mutool", "draw", "-q", "-F", "txt", "-o", "-", pdf],
        "pdftotext": ["pdftotext", "-q", "-bbox", pdf, "-"],
    }


def chars(text: str):
    return collections.Counter(c for c in text if not c.isspace())


def check(readers, pdf: Path, strict: bool, changed_output: bool):
    """Runs each reader once; returns (pages, zpdf's character count, whether zpdf-base read the
    same). Exits on a failed check."""
    outs = {}
    for name, argv in reader_commands(readers, pdf).items():
        p = subprocess.run([str(a) for a in argv], capture_output=True, text=True, errors="replace")
        if p.returncode != 0:
            sys.exit(f"bench-read: {name} failed on {pdf}:\n{p.stderr[-2000:]}")
        outs[name] = p.stdout
    doc = json.loads(outs["zpdf"])
    zpdf = chars("".join(r["text"] for page in doc["pages"] for r in page["runs"]))
    mutool = chars(subprocess.run(["mutool", "draw", "-q", "-F", "txt", "-o", "-", str(pdf)],
                                  capture_output=True, text=True, check=True).stdout)
    if sum(zpdf.values()) == 0 or sum(mutool.values()) == 0:
        sys.exit(f"bench-read: {pdf}: a reader read no characters (zpdf {sum(zpdf.values())}, mutool {sum(mutool.values())})")
    if outs["zpdf-safe"] != outs["zpdf"]:
        sys.exit(f"bench-read: {pdf}: zpdf-safe read something else than zpdf")
    if outs["zpdf-base"] != outs["zpdf"]:
        if not changed_output:
            sys.exit(f"bench-read: {pdf}: zpdf-base read something else than zpdf (--changed-output if meant)")
        print(f"  note: {pdf.name}: zpdf reads something else than zpdf-base, so the two are not timed against each other")
    if zpdf != mutool:
        diff = (zpdf - mutool) + (mutool - zpdf)
        msg = f"{pdf.name}: zpdf and mutool differ in {sum(diff.values())} characters, e.g. {list(diff.items())[:5]}"
        if strict:
            sys.exit("bench-read: " + msg)
        print("  note: " + msg)
    return len(doc["pages"]), sum(zpdf.values()), outs["zpdf-base"] == outs["zpdf"]


def write_corpus(work: Path, scenarios, font: Path):
    """The scenarios' PDFs from each bench-ab writer that draws them; returns the paths."""
    exes = ab.build(work / "writers", "HEAD")
    pdfs = []
    for name, count in scenarios:
        for tool, exe in exes.items():
            if tool == "zpdf-base" or (name.endswith("-std") and tool not in ab.STANDARD_WRITERS):
                continue
            out = work / f"{name}-{tool}.pdf"
            run([str(exe), name, str(font), count, str(out)], cwd=REPO)
            pdfs.append(out)
    return pdfs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="main")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--scenario", action="append")
    ap.add_argument("--pdf", action="append", default=[], type=Path)
    ap.add_argument("--changed-output", action="store_true")
    args = ap.parse_args()
    if args.runs < 5:
        sys.exit("bench-read: --runs must be at least 5")
    scenarios = [s.split(":") for s in (args.scenario or ["grid:20000", "text:20"])]
    regressions = []
    with tempfile.TemporaryDirectory(prefix="zpdf-bench-read-") as tmp:
        work = Path(tmp)
        (work / "writers").mkdir()
        readers = build_readers(work, args.base)
        corpus = [(p, True) for p in write_corpus(work, scenarios, ab.harfbuzz_test_dir() / ab.FONT)]
        corpus += [(p.resolve(), False) for p in args.pdf]
        for pdf, strict in corpus:
            pages, n, same_as_base = check(readers, pdf, strict, args.changed_output)
            stats = ab.hyperfine(reader_commands(readers, pdf), args.runs, work / f"{pdf.stem}.json")
            print(f"\n{pdf.name}: {pages} pages, {n} characters, {pdf.stat().st_size / 1e6:.1f} MB, hyperfine {args.runs} runs each")
            for name, r in stats.items():
                t = r["time_wall_clock"]
                print(f"  {name:10s} median {t['median'] * 1e3:8.1f} ms  ({pages / t['median']:8.0f} pages/s)"
                      f"  range {t['min'] * 1e3:.1f}-{t['max'] * 1e3:.1f} ms  peak {r['memory_peak_resident']['max'] / 1e6:6.1f} MB"
                      f"  {r['instructions']['median'] / 1e6:9.1f} M instructions")
            new = stats["zpdf"]["time_wall_clock"]
            for other in ("zpdf-safe", "zpdf-base", "mutool", "pdftotext"):
                o = stats[other]["time_wall_clock"]
                apart = new["min"] > o["max"] or new["max"] < o["min"]
                insn = stats["zpdf"]["instructions"]["median"] / stats[other]["instructions"]["median"]
                print(f"  zpdf / {other}: {new['median'] / o['median']:.2f}x time "
                      f"{'(ranges do not overlap)' if apart else '(ranges overlap)'}, {insn:.2f}x instructions")
            # Reading something else is not a slowdown: a regression needs the same output.
            if same_as_base and new["min"] > stats["zpdf-base"]["time_wall_clock"]["max"]:
                # Five runs that happen not to overlap are not enough: identical code has done it
                # (2026-10-16, 1.00x instructions, 9% apart). Confirm with three times the runs,
                # zpdf and zpdf-base only, before calling it a regression.
                cmds = {k: v for k, v in reader_commands(readers, pdf).items() if k in ("zpdf", "zpdf-base")}
                again = ab.hyperfine(cmds, args.runs * 3, work / f"{pdf.stem}-again.json")
                a, b = again["zpdf"]["time_wall_clock"], again["zpdf-base"]["time_wall_clock"]
                print(f"  confirm, {args.runs * 3} runs: zpdf {a['median'] * 1e3:.1f} ms, zpdf-base {b['median'] * 1e3:.1f} ms"
                      f" ({'still apart' if a['min'] > b['max'] else 'overlap'})")
                if a["min"] > b["max"]:
                    regressions.append(pdf.name)
    if regressions:
        sys.exit(f"bench-read: slower than {args.base} on: {', '.join(regressions)}")


if __name__ == "__main__":
    main()
