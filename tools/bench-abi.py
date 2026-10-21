# /// script
# requires-python = ">=3.11"
# ///
"""Time libzpdf through its C ABI, as .NET and C call it: this tree against --base.

    uv run tools/bench-abi.py [--base main] [--runs 10]

Builds libzpdf (`zig build abi`, ReleaseSafe as it ships, baseline CPU as native-all builds it) from
this tree and from --base (a detached worktree), and tools/bench-abi.c from this tree against each.
Cases: write the grid with 1 and 4 threads, and read a PDF's text with 1 and 4 threads, each thread
with its own context (bench-abi.c says what each does). The two builds alternate run by run, so
drift on the machine falls on both.

Each case must give the same output bytes, above zero, in every run of both builds, or the
comparison stops: a build that did other work, or none, is not slower or faster. Prints, per case
and build, wall time (median, min to max) and peak RSS (median).

Exit status 1 when this tree is slower than the base on a case, with no overlap between the two
sets of runs, twice: a first gap is re-run with three times the runs, and only a gap that stays
counts. Nothing is stored.

Runs on Linux and macOS (bench-abi.c uses pthreads and getrusage). The base must have this tree's
ABI, or the harness does not compile against it.
"""

import argparse
import importlib.util
import statistics
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

BUILDS = ("new", "base")


def build(work: Path, base: str):
    def lib_and_harness(tree: Path, name: str):
        prefix = work / name
        run([ab.ZIG, "build", "abi", "-Dcpu=baseline", "--prefix", str(prefix)], cwd=tree)
        # rpath, so each harness loads its own libzpdf whatever the environment says.
        run([ab.ZIG, "cc", "-O2", str(REPO / "tools/bench-abi.c"), f"-I{prefix}/include", f"-L{prefix}/lib",
             f"-Wl,-rpath,{prefix}/lib", "-lzpdf", "-lpthread", "-o", str(prefix / "bench-abi")], cwd=REPO)
        return prefix / "bench-abi"

    harness = {"new": lib_and_harness(REPO, "new")}
    tree = work / "base-tree"
    run(["git", "worktree", "add", "--detach", str(tree), base], cwd=REPO)
    try:
        harness["base"] = lib_and_harness(tree, "base")
    finally:
        run(["git", "worktree", "remove", "--force", str(tree)], cwd=REPO)
    return harness


def measure(harness, cases, runs):
    """{case: {build: [(wall_ms, maxrss_kb)]}}, stopping when any run's output bytes differ."""
    results = {case: {b: [] for b in BUILDS} for case in cases}
    seen_bytes = {case: set() for case in cases}
    for _ in range(runs):
        for case, argv in cases.items():
            for b in BUILDS:
                line = run([harness[b], *argv])
                fields = dict(f.split("=") for f in line.split())
                results[case][b].append((int(fields["wall_ms"]), int(fields["maxrss_kb"])))
                seen_bytes[case].add(int(fields["bytes"]))
    for case, seen in seen_bytes.items():
        if len(seen) != 1 or 0 in seen:
            sys.exit(f"bench-abi: {case}: output bytes {sorted(seen)} across runs and builds; "
                     "the builds did different work, so their times mean nothing")
    return results


def slower(times):
    """This tree slower than the base, with no overlap between their runs."""
    return min(w for w, _ in times["new"]) > max(w for w, _ in times["base"])


def report(results, runs):
    print(f"{sys.platform}, {runs} runs per build and case")
    for case, by_build in results.items():
        for b in BUILDS:
            walls = [w for w, _ in by_build[b]]
            rss = statistics.median(r for _, r in by_build[b]) / 1024
            print(f"{case:<18} {b:<5} wall ms median {statistics.median(walls):7.0f} "
                  f"({min(walls)} to {max(walls)})   peak RSS MB median {rss:6.1f}")
    # Before any message on stderr, so the table comes first.
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base", default="main")
    parser.add_argument("--runs", type=int, default=10)
    args = parser.parse_args()

    font = ab.harfbuzz_test_dir() / ab.FONT
    with tempfile.TemporaryDirectory(prefix="zpdf-bench-abi-") as tmp:
        work = Path(tmp)
        harness = build(work, args.base)
        pdf = work / "input.pdf"
        run([harness["new"], "write", "1", "20000", font, pdf])
        cases = {
            "write 1 thread": ["write", "1", "100000", font, "-"],
            "write 4 threads": ["write", "4", "100000", font, "-"],
            "read 1 thread": ["read", "1", "5", pdf],
            "read 4 threads": ["read", "4", "5", pdf],
        }
        results = measure(harness, cases, args.runs)
        report(results, args.runs)
        gaps = {case: argv for case, argv in cases.items() if slower(results[case])}
        if gaps:
            print(f"bench-abi: slower than {args.base} on {', '.join(gaps)}; re-running those with "
                  f"{3 * args.runs} runs", file=sys.stderr)
            again = measure(harness, gaps, 3 * args.runs)
            report(again, 3 * args.runs)
            stayed = [case for case in gaps if slower(again[case])]
            if stayed:
                print(f"bench-abi: this tree is slower than {args.base} on {', '.join(stayed)}", file=sys.stderr)
                sys.exit(1)


if __name__ == "__main__":
    main()
