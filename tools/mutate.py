# /// script
# requires-python = ">=3.11"
# ///
"""Mutation testing: break the code on purpose and check that a test fails.

    uv run tools/mutate.py <mutants.json> [index ...]

mutants.json is a list of [path, old, new, step]: `old` must occur exactly once in `path`; it is
replaced by `new`, `zig build <step>` runs (step "test", "web-test" or "dotnet-test"), and the file is restored,
also when the run is interrupted. Write mutants that compile: a mutant that does not is reported
as COMPILE ERROR and proves nothing.

Each line of output is one mutant:
    <index> killed <the first failing test, or the check program that failed>
    <index> SURVIVED
    <index> COMPILE ERROR <the first error>
    <index> TIMEOUT after 900 s   (a hang: no test named, so it needs reading)
A kill must name a failing test. A kill with no failing test named (NO FAILING TEST FOUND) is a
failure of something else, such as a timeout or a build step, and needs reading.

The mutated file is formatted with `zig fmt` before the build, because `zig build test` checks
formatting: a mutant that deletes a line leaves a blank line, which would otherwise fail the
format check and count as a kill that no test made. That happened (2026-10-16), and three such
false kills went unnoticed for one run.

Exit status: 1 when any mutant survived or did not compile.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

# The zig this checkout builds with (tools/zig says how it is chosen).
ZIG = str(Path(__file__).resolve().parent / "zig")


def main():
    mutants = json.load(open(sys.argv[1]))
    only = {int(a) for a in sys.argv[2:]}
    bad = 0
    for i, (path, old, new, step) in enumerate(mutants):
        if only and i not in only:
            continue
        orig = open(path).read()
        if orig.count(old) != 1:
            sys.exit(f"mutant {i}: the text to replace occurs {orig.count(old)} times in {path}, not once")
        open(path, "w").write(orig.replace(old, new))
        try:
            if path.endswith(".zig"):
                subprocess.run([ZIG, "fmt", path], capture_output=True)
            # errors="replace": a failing test can print any bytes (freed memory, poisoned as 0xaa).
            try:
                p = subprocess.run([ZIG, "build", step], capture_output=True, text=True, errors="replace", timeout=900)
            except subprocess.TimeoutExpired:
                # A hang is not a named kill: something waited forever, which needs reading.
                bad += 1
                print(i, "TIMEOUT after 900 s", flush=True)
                continue
            out = p.stdout + p.stderr
            lines = out.splitlines()
            # A failing test: Zig's test runner, xunit's "<test> [FAIL]" (dotnet-test), or a check
            # program that ran and failed ("run exe check-exports failure" in the build summary). A
            # mutant can fail one of these and also break a build elsewhere; the check names the kill.
            named = next((l.strip() for l in lines if re.match(r"error: '.*' (failed|terminated)", l)
                          or l.rstrip().endswith("[FAIL]") or re.search(r"run exe \S+ failure$", l.rstrip())), "")
            if p.returncode == 0:
                verdict, why = "SURVIVED", ""
            elif named:
                verdict, why = "killed", named
            elif "compilation error" in out or re.search(r"error CS\d+", out):
                verdict, why = "COMPILE ERROR", next((l for l in lines if ": error:" in l or re.search(r"error CS\d+", l)), "")
            else:
                verdict, why = "killed", "NO FAILING TEST FOUND: " + " | ".join(lines[-3:])
            if verdict != "killed":
                bad += 1
            print(i, verdict, why[:200], flush=True)
        finally:
            open(path, "w").write(orig)
    sys.exit(1 if bad else 0)


main()
