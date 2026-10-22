# /// script
# requires-python = ">=3.11"
# dependencies = ["pdfminer.six==20260107"]
# ///
"""Checks every code of zpdf's predefined CMaps (src/cmap, Table 118) against two other readings.

    zig build cmap-test        (or: uv run tools/cmap-oracle.py --exe <cmap-dump>)

zpdf's side is tools/cmap-dump.zig: each CMap as the text reader reads it, through the compiled
blob: every code of its codespace with its CID, or with its notdef CID when it has no mapping.

1. Adobe's CMap file, read by the small parser below (regular expressions, usecmap followed),
   which shares no code with zpdf's. It must agree on every code inside zpdf's codespace:
   mapping, CID and notdef CID. Any difference fails.
2. pdfminer.six's own tables (pdfminer/cmap/*.json.gz), which its tools build from Adobe's
   cid2code.txt, not from the CMap files, so they also check how the files are read (for
   example that a multi-byte cidrange is a range of numbers). Where pdfminer differs, the code is
   counted by kind: "pdfminer differs from Adobe's file" when zpdf and the file agree, which is a
   difference between Adobe's two data sources and fails nothing. pdfminer has no notdef data.

Exit status 1 when check 1 fails anywhere, or when a CMap compared no code (a broken run).
"""

import argparse
import collections
import re
import subprocess
import sys
from pathlib import Path

from pdfminer.cmapdb import CMapDB


def adobe_file(name):
    """({(length, code): cid}, {(length, code): notdef cid}) from src/cmap/<name>, usecmap first."""
    text = Path("src/cmap", name).read_text(encoding="latin-1")
    cids, notdefs = {}, {}
    use = re.search(r"/(\S+)\s+usecmap", text)
    if use:
        cids, notdefs = adobe_file(use.group(1))
        cids, notdefs = dict(cids), dict(notdefs)
    for kind, target in (("cid", cids), ("notdef", notdefs)):
        for block in re.findall(rf"begin{kind}range(.*?)end{kind}range", text, re.S):
            for lo, hi, cid in re.findall(r"<([0-9a-fA-F]+)>\s*<([0-9a-fA-F]+)>\s*(\d+)", block):
                for k in range(int(hi, 16) - int(lo, 16) + 1):
                    # A cidrange counts up from its CID; a notdefrange maps every code to its
                    # one CID (Adobe TN 5014, beginnotdefrange).
                    target[(len(lo) // 2, int(lo, 16) + k)] = int(cid) + (k if kind == "cid" else 0)
        for block in re.findall(rf"begin{kind}char(.*?)end{kind}char", text, re.S):
            for code, cid in re.findall(r"<([0-9a-fA-F]+)>\s*(\d+)", block):
                target[(len(code) // 2, int(code, 16))] = int(cid)
    return cids, notdefs


def pdfminer_codes(name):
    """{(length, code): cid} from pdfminer's table for `name`."""
    out = {}

    def walk(d, prefix):
        for byte, v in d.items():
            if isinstance(v, int):
                code = prefix + bytes([byte])
                out[(len(code), int.from_bytes(code, "big"))] = v
            else:
                walk(v, prefix + bytes([byte]))

    walk(CMapDB.get_cmap(name).code2cid, b"")
    return out


def in_codespace(key, spaces):
    n, code = key
    b = code.to_bytes(n, "big")
    for sn, lo, hi in spaces:
        if sn != n:
            continue
        lo_b, hi_b = lo.to_bytes(n, "big"), hi.to_bytes(n, "big")
        if all(lo_b[i] <= b[i] <= hi_b[i] for i in range(n)):
            return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", required=True, help="tools/cmap-dump.zig, built")
    args = ap.parse_args()
    names = sorted(p.name for p in Path("src/cmap").iterdir())
    dump = subprocess.run([args.exe, *names], capture_output=True, text=True, check=True).stdout
    spaces = collections.defaultdict(list)
    zpdf = collections.defaultdict(dict)
    zpdf_nd = collections.defaultdict(dict)
    for line in dump.splitlines():
        f = line.split()
        if f[1] == "cs":
            spaces[f[0]].append((int(f[2]), int(f[3], 16), int(f[4], 16)))
        elif f[1] == "nd":
            zpdf_nd[f[0]][(int(f[3]), int(f[2], 16))] = int(f[4])
        else:
            zpdf[f[0]][(int(f[2]), int(f[1], 16))] = int(f[3])

    failed = 0
    totals = collections.Counter()
    for name in names:
        ours = zpdf[name]
        file_cids, file_nd = adobe_file(name)
        theirs = pdfminer_codes(name)
        res = collections.Counter()
        notes = []
        # 1. Adobe's file, inside zpdf's codespace.
        for key in ours.keys() | file_cids.keys():
            if not in_codespace(key, spaces[name]):
                res["file maps it outside the codespace"] += 1
                continue
            a, b = ours.get(key), file_cids.get(key)
            if a == b:
                res["same as Adobe's file"] += 1
            else:
                res["Adobe's file FAIL"] += 1
                if len(notes) < 5:
                    notes.append(f"    <{key[1]:0{2 * key[0]}x}>: zpdf {a}, Adobe's file {b}")
        for key in zpdf_nd[name].keys() | {k for k in file_nd if k not in file_cids and in_codespace(k, spaces[name])}:
            a, b = zpdf_nd[name].get(key), file_nd.get(key)
            if a == b:
                res["notdef same as Adobe's file"] += 1
            else:
                res["notdef FAIL"] += 1
                if len(notes) < 5:
                    notes.append(f"    notdef <{key[1]:0{2 * key[0]}x}>: zpdf {a}, Adobe's file {b}")
        # 2. pdfminer.
        for key in ours.keys() | theirs.keys():
            if key not in ours and not in_codespace(key, spaces[name]):
                continue
            a, b = ours.get(key), theirs.get(key)
            if a == b:
                res["same as pdfminer"] += 1
            elif a == file_cids.get(key):
                res["pdfminer differs from Adobe's file"] += 1
            else:
                res["pdfminer FAIL"] += 1
        bad = any(k.endswith("FAIL") for k in res) or res["same as Adobe's file"] == 0
        failed += bad
        totals.update(res)
        print(f"{'FAIL' if bad else 'ok  '} {name}: " + ", ".join(f"{k} {v}" for k, v in sorted(res.items())))
        for n in notes:
            print(n)
    print(f"\n{len(names)} CMaps, {failed} failed")
    for k, v in sorted(totals.items()):
        print(f"  {k}: {v}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
