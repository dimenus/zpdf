# /// script
# requires-python = ">=3.11"
# ///
"""Run zpdf-read over damaged copies of PDFs and report every crash and hang.

    uv run tools/read-fuzz.py [--exe PATH] [--seed N] [--count N] [--jobs N] [--keep DIR] PDF [...]

PDFs are untrusted input to zpdf.read, so every file must either be read or be refused with an
error. Each given PDF is damaged --count times, the same way for the same --seed (a finding is
replayed with its seed, file and index; the files are not kept):
  bytes     1 to 8 random bytes set anywhere
  number    one number token near a structure keyword (xref entries, startxref, /Length, /W,
            /Index, /First, /N, /Size, /Prev, /Count, /FirstChar, /Widths, Tf, Td, Tm, TJ)
            set to 0, -1, a huge value or one off
  truncate  the file cut at a random point
  splice    a random range deleted, or repeated
Number mutations only bite where the structure is plain text, so give it uncompressed files as
well (qpdf --qdf --object-streams=disable makes one from any PDF).

The default exe is a Debug build of zpdf-read (`zig build` puts it in zig-out/bin): Zig's safety
checks are on, so a defect stops the process instead of passing silently. Run it with a
ReleaseFast build too (--exe), since an unchecked defect can behave differently there.

Outcomes:
  read     exit 0 with JSON pages
  refused  exit 1 with JSON {"error": ...}
  crash    any signal, a panic, any other exit, or output that is not that JSON
  timeout  more than --timeout seconds
Crashes and timeouts are grouped by the first src/ frame in the stack trace. Exit 1 if any input
crashed or timed out, 2 if the sweep did no work.
"""

import argparse
import collections
import concurrent.futures
import json
import random
import re
import subprocess
import sys
import tempfile
from pathlib import Path

FRAME = re.compile(r"(src/[a-z_\-]+\.zig):(\d+)")
KEYWORDS = re.compile(
    rb"(xref|startxref|/Length|/W|/Index|/First|/N|/Size|/Prev|/Count|/FirstChar|/Widths|/DW|Tf|Td|TD|Tm|TJ|Tz|cm|obj|R)\b"
)
NUMBER = re.compile(rb"-?\d+(\.\d+)?")
EXTREMES = [b"0", b"-1", b"4294967295", b"99999999999999999999", b"2147483648", b"-2147483649", b"1e9"]


def damage(data: bytes, rnd: random.Random) -> tuple[str, bytes]:
    kind = rnd.choice(["bytes", "number", "number", "truncate", "splice"])
    b = bytearray(data)
    if kind == "bytes":
        for _ in range(rnd.randint(1, 8)):
            b[rnd.randrange(len(b))] = rnd.randrange(256)
    elif kind == "number":
        spots = [m.end() for m in KEYWORDS.finditer(data)]
        if not spots:
            return damage(data, rnd)
        at = rnd.choice(spots)
        # The nearest number within 40 bytes either side.
        window = data[max(0, at - 40) : at + 40]
        nums = list(NUMBER.finditer(window))
        if not nums:
            return damage(data, rnd)
        m = rnd.choice(nums)
        start, end = max(0, at - 40) + m.start(), max(0, at - 40) + m.end()
        old = data[start:end]
        if rnd.random() < 0.3 and old.lstrip(b"-").isdigit():
            new = str(int(old) + rnd.choice([-1, 1])).encode()
        else:
            new = rnd.choice(EXTREMES)
        b[start:end] = new
    elif kind == "truncate":
        del b[rnd.randrange(1, len(b)) :]
    else:
        i = rnd.randrange(len(b))
        j = min(len(b), i + rnd.randint(1, 256))
        if rnd.random() < 0.5:
            del b[i:j]
        else:
            b[i:i] = b[i:j]
    return kind, bytes(b)


def run_one(exe: str, path: Path, timeout: float) -> tuple[str, str]:
    try:
        p = subprocess.run([exe, str(path)], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "timeout", ""
    err = p.stderr.decode("utf-8", "replace")
    if p.returncode in (0, 1):
        try:
            out = json.loads(p.stdout)
            if p.returncode == 0 and "pages" in out or p.returncode == 1 and "error" in out:
                return ("read" if p.returncode == 0 else "refused"), ""
        except json.JSONDecodeError:
            pass
    frame = FRAME.search(err)
    where = f"{frame.group(1)}:{frame.group(2)}" if frame else f"exit {p.returncode}"
    first = next((line for line in err.splitlines() if line.strip()), "")
    return "crash", f"{where} {first[:120]}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", default=str(Path(__file__).resolve().parent.parent / "zig-out/bin/zpdf-read"))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--count", type=int, default=500)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=float, default=10)
    ap.add_argument("--keep", help="copy each file that crashed or timed out into this directory")
    ap.add_argument("pdfs", nargs="+")
    args = ap.parse_args()
    outcomes = collections.Counter()
    found = collections.defaultdict(list)
    with tempfile.TemporaryDirectory(prefix="read-fuzz-") as tmp:
        jobs = []
        for n, pdf in enumerate(args.pdfs):
            data = Path(pdf).read_bytes()
            rnd = random.Random(f"{args.seed}:{Path(pdf).name}")
            for i in range(args.count):
                kind, damaged = damage(data, rnd)
                # The input's position in the arguments too: two inputs can share a file name.
                path = Path(tmp) / f"{n}-{Path(pdf).stem}-{i}.pdf"
                path.write_bytes(damaged)
                jobs.append((pdf, i, kind, path))
        with concurrent.futures.ThreadPoolExecutor(args.jobs) as ex:
            results = ex.map(lambda j: (j, run_one(args.exe, j[3], args.timeout)), jobs)
            for (pdf, i, kind, _), (outcome, detail) in results:  # noqa: B007 (_ is the damaged file)
                outcomes[outcome] += 1
                outcomes[f"{outcome} ({kind})"] += 1
                if outcome in ("crash", "timeout"):
                    found[detail or outcome].append(f"seed {args.seed} {Path(pdf).name} #{i} ({kind})")
                    if args.keep:
                        Path(args.keep).mkdir(parents=True, exist_ok=True)
                        (Path(args.keep) / _.name).write_bytes(_.read_bytes())
    for k in sorted(outcomes):
        print(f"{k}: {outcomes[k]}")
    for where, cases in sorted(found.items(), key=lambda kv: -len(kv[1])):
        print(f"\n{len(cases)} x {where}")
        for c in cases[:5]:
            print(f"    {c}")
    if not outcomes["read"] and not outcomes["refused"]:
        sys.exit(2)
    sys.exit(1 if found else 0)


main()
