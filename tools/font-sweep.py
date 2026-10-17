# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools"]
# ///
"""Run zpdf-text over many fonts and report every crash and hang.

    uv run tools/font-sweep.py [--exe PATH] [--jobs N] [--out FILE] DIR_OR_FONT [...]

Fonts are untrusted input to zpdf (the wasm build takes them from users), so every font must either
make a PDF or be rejected with an error. Each argument is a font file or a directory; every regular
file under a directory is tried, with or without an extension (HarfBuzz's fuzzing corpus has none).

The default exe is a Debug build of zpdf-text (`zig build` puts it in zig-out/bin): Zig's safety
checks are on, and so is the undefined-behaviour trap in kb's C, so a defect stops the process
instead of passing silently. Each font gets one line of mixed scripts plus up to 200 codepoints
from its own cmap, so its glyphs are actually shaped and embedded.

Outcomes:
  ok       exit 0 and a non-empty PDF
  reject   exit 1 with "zpdf-text: <error>" and no crash frame, the clean refusal
  crash    any signal, a Zig panic, or any other exit
  timeout  more than --timeout seconds

Crashes and timeouts are grouped by the first kb or zpdf source frame in the stack trace. Exit 1
if any font crashed or timed out, 2 if the sweep did no work (no fonts, or none made a PDF).
One TSV line per font goes to --out.
"""

import argparse
import collections
import concurrent.futures
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

MIXED = "office AVA é ﬁ שָׁלוֹם بِسْمِ हिन्दी क्षि 中文 😀"
FRAME = re.compile(r"(kb_text_shape\.h|kb_shim\.c|src/[a-z_\-]+\.zig|std/[\w/]+\.zig):(\d+)")
ERROR_LINE = re.compile(r"^zpdf-text: (\w+)$", re.M)


def cmap_sample(path: str) -> list[int]:
    """Up to 200 codepoints the font maps, spread over its cmap. Empty when fontTools cannot read it."""
    try:
        from fontTools.ttLib import TTFont

        cps = sorted((TTFont(path, lazy=True, fontNumber=0).getBestCmap() or {}).keys())
    except Exception:
        return []
    cps = [c for c in cps if c > 0x20 and not 0xD800 <= c <= 0xDFFF]
    step = max(1, len(cps) // 200)
    return cps[::step][:200]


def run_one(exe: str, font: str, timeout: float, work: Path) -> tuple[str, str, str]:
    out = work / (str(abs(hash(font))) + ".pdf")
    lines = ["--unicodes=" + ",".join(f"U+{ord(c):04X}" for c in MIXED)]
    sample = cmap_sample(font)
    for i in range(0, len(sample), 50):
        lines.append("--unicodes=" + ",".join(f"U+{c:04X}" for c in sample[i : i + 50]))
    try:
        p = subprocess.run([exe, font, f"--out={out}", *lines], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "timeout", "", ""
    made = out.exists() and out.stat().st_size > 0
    if made:
        out.unlink()
    frame = FRAME.search(p.stderr)
    where = f"{frame.group(1)}:{frame.group(2)}" if frame else ""
    first = next((l for l in p.stderr.splitlines() if l.strip()), "")[:160]
    if p.returncode == 0 and made:
        return "ok", "", ""
    err = ERROR_LINE.search(p.stderr)
    if p.returncode == 1 and err and not frame and "panic" not in p.stderr:
        return "reject", err.group(1), ""
    return "crash", where or f"exit {p.returncode}, no frame", first


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--exe", default=str(Path(__file__).resolve().parent.parent / "zig-out" / "bin" / "zpdf-text"))
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--timeout", type=float, default=30)
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()

    fonts = []
    for p in map(Path, args.paths):
        if p.is_dir():
            fonts += sorted(str(f) for f in p.rglob("*") if f.is_file())
        elif p.is_file():
            fonts.append(str(p))
        else:
            sys.exit(f"font-sweep: {p} does not exist")
    if not fonts:
        sys.exit(2)

    work = Path(tempfile.mkdtemp(prefix="zpdf-sweep-"))
    results = {}
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = {pool.submit(run_one, args.exe, f, args.timeout, work): f for f in fonts}
        for fut in concurrent.futures.as_completed(futures):
            results[futures[fut]] = fut.result()

    if args.out:
        args.out.write_text("".join(f"{f}\t{k}\t{a}\t{b}\n" for f, (k, a, b) in sorted(results.items())))
    kinds = collections.Counter(k for k, _, _ in results.values())
    print(f"fonts {len(fonts)}: " + ", ".join(f"{k} {kinds[k]}" for k in ("ok", "reject", "crash", "timeout")))
    rejects = collections.Counter(a for k, a, _ in results.values() if k == "reject")
    print("rejected as: " + ", ".join(f"{e} {n}" for e, n in rejects.most_common()))
    groups = collections.defaultdict(list)
    for f, (k, a, b) in results.items():
        if k in ("crash", "timeout"):
            groups[(k, a or "-")].append((f, b))
    for (k, where), items in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        f, first = sorted(items)[0]
        print(f"{len(items):5d}  {k:7} {where}\n       e.g. {f}\n       {first}")
    if kinds["ok"] == 0:
        sys.exit(2)
    sys.exit(1 if kinds["crash"] or kinds["timeout"] else 0)


if __name__ == "__main__":
    main()
