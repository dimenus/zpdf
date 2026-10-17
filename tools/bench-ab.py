# /// script
# requires-python = ">=3.11"
# ///
"""Time zpdf against its own base (regressions) and against MuPDF (the baseline), on the same pages.

    uv run tools/bench-ab.py [--base main] [--runs 5] [--scenario grid:200000] [--scenario text:100]

Builds the writers: zpdf-bench from this tree and from --base (a detached worktree), both
ReleaseFast; tools/bench-mupdf.c against Homebrew's mupdf-tools (libmupdf.a); tools/bench-cairo.c
against Homebrew's cairo, harfbuzz and freetype. WRITERS below says which writers shape text and embed
the font, since a writer that does neither does less work. Each scenario is
timed by hyperfine 2 (2 warm-up runs, then --runs runs per program, no shell). Reported per program:
wall time (mean, standard deviation, median, range), peak resident memory and CPU instructions, all
from hyperfine's JSON. Instructions vary far less than wall time between runs, so a small change
shows there first.

Before timing, each scenario is checked once: every PDF must have the same page count and extract to the
same characters in the same order (mutool draw -F txt, whitespace removed: where a reader puts word breaks
depends on glyph spacing, which differs between writers), so a program that wrote nothing cannot look fast.

Exit status 1 when this tree is slower than --base on a scenario and the two sets of runs do not overlap
(the slowest base run is faster than the fastest branch run). Nothing is stored: the numbers are
measured fresh each time. Needs zig, hyperfine, mutool, and Homebrew's mupdf-tools, cairo, harfbuzz
and freetype headers and libraries.
"""

import argparse
import json
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
# The zig each checkout builds with: tools/zig picks it from the build.zig.zon of the directory it
# runs in, so the base worktree gets the version the base needs.
ZIG = str(REPO / "tools/zig")
FONT = "subset/data/fonts/Roboto-Regular.ttf"
MUPDF = Path("/opt/homebrew")


# Scenarios ending in -std draw zpdf's standard Helvetica (named, not embedded, no shaping); only
# writers that can draw the same way take part in them.
STANDARD_WRITERS = {"zpdf", "zpdf-base"}

# name: (shapes text, embeds the font). Printed beside the timings; zpdf neither shapes nor embeds
# in a -std scenario.
WRITERS = {
    "zpdf": (True, True),
    "zpdf-base": (True, True),
    "mupdf": (False, True),
    "cairo": (True, True),
}


def run(cmd, cwd=None):
    # Output goes to files, not pipes: a helper process that outlives the command while holding its
    # stderr would make reading a pipe to its end never return.
    with tempfile.TemporaryFile("w+") as out, tempfile.TemporaryFile("w+") as err:
        p = subprocess.run(cmd, cwd=cwd, stdout=out, stderr=err, text=True)
        out.seek(0)
        err.seek(0)
        if p.returncode != 0:
            sys.exit(f"bench-ab: {' '.join(map(str, cmd))} failed:\n{err.read()[-2000:]}")
        return out.read()


def harfbuzz_test_dir():
    zon = (REPO / "build.zig.zon").read_text()
    m = re.search(r"\.harfbuzz = \.\{.*?\.hash = \"([^\"]+)\"", zon, re.S)
    path = REPO / "zig-pkg" / m.group(1) / "test"
    if not path.is_dir():
        sys.exit(f"bench-ab: {path} missing; run zig build once to fetch dependencies")
    return path


def build(work: Path, base: str):
    zpdf_new = work / "new"
    run([ZIG, "build", "bench", "-Doptimize=ReleaseFast", "--prefix", str(zpdf_new)], cwd=REPO)
    tree = work / "base-tree"
    run(["git", "worktree", "add", "--detach", str(tree), base], cwd=REPO)
    zpdf_base = work / "base"
    try:
        # Both sides run this tree's workload, so a scenario means the same pages on each.
        own_bench = (tree / "tools/bench.zig").read_text() if (tree / "tools/bench.zig").exists() else None
        (tree / "tools/bench.zig").write_text((REPO / "tools/bench.zig").read_text())
        build_zig = (tree / "build.zig").read_text()
        if "zpdf-bench" not in build_zig:
            ours = (REPO / "build.zig").read_text()
            block = ours[ours.index("    // bench-ab:begin"):ours.index("    // bench-ab:end")]
            anchor = "    // The PDFs zpdf-text makes for tests/golden/cases.tsv must hash to"
            if anchor not in build_zig:
                sys.exit(f"bench-ab: cannot add the bench step to {base}'s build.zig")
            (tree / "build.zig").write_text(build_zig.replace(anchor, block + anchor, 1))
        built = subprocess.run([ZIG, "build", "bench", "-Doptimize=ReleaseFast", "--prefix", str(zpdf_base)],
                               cwd=tree, capture_output=True, text=True)
        if built.returncode != 0:
            # This tree's workload uses API the base lacks: build the base's own bench.zig, and
            # leave the base out of scenarios it does not know (zpdf-bench exits 2 for those).
            if own_bench is None:
                sys.exit(f"bench-ab: {base} cannot build this tree's bench.zig:\n{built.stderr[-2000:]}")
            (tree / "tools/bench.zig").write_text(own_bench)
            print(f"bench-ab: {base} cannot build this tree's bench.zig; using its own", file=sys.stderr)
            run([ZIG, "build", "bench", "-Doptimize=ReleaseFast", "--prefix", str(zpdf_base)], cwd=tree)
    finally:
        run(["git", "worktree", "remove", "--force", str(tree)], cwd=REPO)
    mupdf = work / "bench-mupdf"
    run([ZIG, "cc", "-O2", str(REPO / "tools/bench-mupdf.c"), f"-I{MUPDF}/include",
         f"{MUPDF}/lib/libmupdf.a", f"{MUPDF}/lib/libmupdf-third.a", "-lm", "-o", str(mupdf)])
    cairo = work / "bench-cairo"
    run([ZIG, "cc", "-O2", str(REPO / "tools/bench-cairo.c"), f"-I{MUPDF}/include", f"-I{MUPDF}/include/freetype2",
         f"-L{MUPDF}/lib", "-lcairo", "-lharfbuzz", "-lfreetype", "-o", str(cairo)])
    return {"zpdf": zpdf_new / "bin/zpdf-bench", "zpdf-base": zpdf_base / "bin/zpdf-bench", "mupdf": mupdf, "cairo": cairo}


def hyperfine(commands, runs, out_json):
    """hyperfine's results per command name: its JSON 'results' entries."""
    cmd = ["hyperfine", "-N", "--warmup", "2", "--runs", str(runs), "--export-json", str(out_json), "--style", "none"]
    for name, argv in commands.items():
        cmd += ["--command-name", name, " ".join(shlex.quote(str(a)) for a in argv)]
    run(cmd, cwd=REPO)
    # Results come in the order the commands were given; the JSON names each by its command line,
    # not by --command-name, so match by position and check the command lines line up.
    results = json.loads(out_json.read_text())["results"]
    if len(results) != len(commands):
        sys.exit(f"bench-ab: hyperfine gave {len(results)} results for {len(commands)} commands")
    out = {}
    for (name, argv), r in zip(commands.items(), results):
        if not r["command"].startswith(shlex.quote(str(argv[0]))):
            sys.exit(f"bench-ab: hyperfine result {r['command']!r} is not {name}")
        out[name] = r["summary"]
    return out


def content(pdf: Path):
    """Page count, and the extracted characters in order with whitespace removed."""
    pages = re.search(r"Pages: (\d+)", run(["mutool", "info", str(pdf)])).group(1)
    chars = "".join(run(["mutool", "draw", "-F", "txt", str(pdf)]).split())
    return pages, chars


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="main")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--scenario", action="append")
    args = ap.parse_args()
    if args.runs < 5:
        sys.exit("bench-ab: --runs must be at least 5")
    scenarios = [s.split(":") for s in (args.scenario or ["grid:200000", "text:100"])]
    font = harfbuzz_test_dir() / FONT
    regressions = []
    with tempfile.TemporaryDirectory(prefix="zpdf-bench-") as tmp:
        work = Path(tmp)
        exes = build(work, args.base)
        for name, count in scenarios:
            tools = {t: e for t, e in exes.items() if not name.endswith("-std") or t in STANDARD_WRITERS}
            outs = {tool: work / f"{name}-{tool}.pdf" for tool in tools}
            for tool in list(tools):
                p = subprocess.run([str(tools[tool]), name, str(font), count, str(outs[tool])], cwd=REPO,
                                   capture_output=True, text=True)
                if p.returncode == 2 and tool == "zpdf-base":
                    print(f"bench-ab: {name}: {args.base} does not know this scenario; left out", file=sys.stderr)
                    del tools[tool], outs[tool]
                elif p.returncode != 0:
                    sys.exit(f"bench-ab: {tool} {name} failed:\n{p.stderr[-2000:]}")
            seen = {tool: content(pdf) for tool, pdf in outs.items()}
            pages, chars = seen["zpdf"]
            if len(chars) == 0 or any(v != (pages, chars) for v in seen.values()):
                sys.exit(f"bench-ab: {name}: the PDFs differ in pages or text: "
                         + ", ".join(f"{t} {v[0]} pages {len(v[1])} chars" for t, v in seen.items()))
            commands = {tool: [tools[tool], name, font, count, outs[tool]] for tool in tools}
            stats = hyperfine(commands, args.runs, work / f"{name}.json")
            print(f"\n{name} x{count}: {pages} pages, {len(chars)} characters, hyperfine {args.runs} runs each")
            for tool, r in stats.items():
                t = r["time_wall_clock"]
                shapes, embeds = (False, False) if name.endswith("-std") else WRITERS[tool]
                note = f"{'shapes' if shapes else 'no shaping'}, {'embeds' if embeds else 'no embedding'}"
                print(f"  {tool:10s} {note:24s} mean {t['mean']:7.3f}s ± {t['stddev']:.3f}  median {t['median']:7.3f}s"
                      f"  range {t['min']:.3f}-{t['max']:.3f}s  peak {r['memory_peak_resident']['max'] / 1e6:7.1f} MB"
                      f"  {r['instructions']['median'] / 1e6:9.1f} M instructions")
            new = stats["zpdf"]["time_wall_clock"]
            for other in [t for t in tools if t != "zpdf"]:
                old = stats[other]["time_wall_clock"]
                apart = new["min"] > old["max"] or new["max"] < old["min"]
                insn = stats["zpdf"]["instructions"]["median"] / stats[other]["instructions"]["median"]
                print(f"  zpdf / {other}: {new['median'] / old['median']:.2f}x time "
                      f"{'(ranges do not overlap)' if apart else '(ranges overlap)'}, {insn:.2f}x instructions")
            if "zpdf-base" in stats and new["min"] > stats["zpdf-base"]["time_wall_clock"]["max"]:
                regressions.append(name)
    if regressions:
        sys.exit(f"bench-ab: slower than {args.base} on: {', '.join(regressions)}")


if __name__ == "__main__":
    main()
