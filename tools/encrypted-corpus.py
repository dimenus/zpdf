# /// script
# requires-python = ">=3.11"
# ///
"""A random sample of encrypted PDFs from the web, for checking the reader's decryption.

    uv run tools/encrypted-corpus.py <dir> [--n 300] [--seed 20261021] [--plain]
    zig build && uv run tools/read-oracle.py <dir>/pdfs

--plain draws files that are not encrypted instead, into another <dir>: the base rate. What the
oracle reports on encrypted files means something only next to what it reports on plain files
from the same corpus, since most of the reader's failures there are not about encryption.

The source is Digital Corpora's CC-MAIN-2021-31-PDF-UNTRUNCATED: about 7.9 million PDFs from a
Common Crawl, in zip files of 1000. Its Apache Tika table (metadata/tika-20230714.csv.gz, 448 MB)
says which files are encrypted. The first run streams it once and keeps one line per unique file
in <dir>/files.tsv (a file crawled from several URLs has several rows, and counts once). Then it
draws --n encrypted files with --seed and fetches each one out of its zip with HTTP range
requests, into <dir>/pdfs/ (a file already there is kept). Nothing is uploaded.

It prints, from the table: the files, how many are encrypted, and how many of those Tika parsed;
and, from qpdf (needs qpdf): how many of the sample open with the empty user password, and which
security handler each of those uses. These are the numbers the reader's encryption support was
chosen by; this re-derives them.

The files are untrusted, from the web: keep <dir> outside the repository.
"""

import argparse
import collections
import csv
import gzip
import io
import json
import random
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

BASE = "https://digitalcorpora.s3.amazonaws.com/corpora/files/CC-MAIN-2021-31-PDF-UNTRUNCATED"


def open_url(req):
    for attempt in range(5):
        try:
            return urllib.request.urlopen(req, timeout=60)
        except OSError:
            if attempt == 4:
                raise
            time.sleep(2**attempt)


def files_table(out: Path) -> Path:
    """<out>/files.tsv: file name, Tika's encrypted flag, Tika's parse status; one line per file."""
    path = out / "files.tsv"
    if path.exists():
        return path
    csv.field_size_limit(1 << 30)
    seen = {}
    with open_url(f"{BASE}/metadata/tika-20230714.csv.gz") as r:
        text = io.TextIOWrapper(gzip.GzipFile(fileobj=r), encoding="utf-8-sig")
        for row in csv.DictReader(text):
            seen.setdefault(row["file_name"], (row["encrypted"], row["parse_status"]))
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w") as f:
        for name, (enc, status) in seen.items():
            f.write(f"{name}\t{enc}\t{status}\n")
    tmp.rename(path)
    return path


class HttpRange(io.RawIOBase):
    """A seekable read-only file over HTTP range requests, enough for zipfile."""

    def __init__(self, url):
        self.url = url
        with open_url(urllib.request.Request(url, method="HEAD")) as r:
            self.size = int(r.headers["Content-Length"])
        self.pos = 0

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        self.pos = {0: offset, 1: self.pos + offset, 2: self.size + offset}[whence]
        return self.pos

    def readinto(self, b):
        if self.pos >= self.size or len(b) == 0:
            return 0
        end = min(self.pos + len(b), self.size) - 1
        with open_url(urllib.request.Request(self.url, headers={"Range": f"bytes={self.pos}-{end}"})) as r:
            data = r.read()
        if len(data) != end - self.pos + 1:
            raise OSError(f"short range read: {len(data)} of {end - self.pos + 1}")
        b[: len(data)] = data
        self.pos += len(data)
        return len(data)


def fetch(names, pdfs: Path):
    """Each file out of its zip: 0001234.pdf is in zipfiles/0000-0999/0001.zip."""
    by_zip = collections.defaultdict(list)
    for name in names:
        if not (pdfs / name).exists():
            by_zip[int(name[:7]) // 1000].append(name)
    failed = []
    for n, wanted in sorted(by_zip.items()):
        group = n // 1000 * 1000
        url = f"{BASE}/zipfiles/{group:04d}-{group + 999:04d}/{n:04d}.zip"
        try:
            with zipfile.ZipFile(io.BufferedReader(HttpRange(url), buffer_size=1 << 20)) as z:
                members = {Path(i.filename).name: i for i in z.infolist()}
                for name in wanted:
                    if name not in members:
                        failed.append(name)
                        continue
                    (pdfs / name).write_bytes(z.read(members[name]))
        except (OSError, zipfile.BadZipFile) as e:
            print(f"encrypted-corpus: {url}: {e}", file=sys.stderr)
            failed += wanted
    if failed:
        sys.exit(f"encrypted-corpus: {len(failed)} files not fetched: {' '.join(failed)}")


def census(pdfs: Path, names):
    status = collections.Counter()
    handlers = collections.Counter()
    for name in names:
        path = str(pdfs / name)
        code = subprocess.run(["qpdf", "--requires-password", path], capture_output=True).returncode
        status[{0: "needs a password", 2: "not encrypted (qpdf)", 3: "opens with the empty user password"}.get(code, f"qpdf exit {code}")] += 1
        if code != 3:
            continue
        p = subprocess.run(["qpdf", "--json", "--json-key=encrypt", path], capture_output=True, text=True)
        if p.returncode not in (0, 3):
            handlers[f"qpdf --json exit {p.returncode}"] += 1
            continue
        e = json.loads(p.stdout)["encrypt"]["parameters"]
        handlers[f"R{e['R']} V{e['V']} {e['bits']}-bit streams={e['streammethod']} strings={e['stringmethod']}"] += 1
    return status, handlers


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("dir", type=Path)
    ap.add_argument("--n", type=int, default=300)
    ap.add_argument("--seed", type=int, default=20261021)
    ap.add_argument("--plain", action="store_true", help="files that are not encrypted")
    args = ap.parse_args()
    args.dir.mkdir(parents=True, exist_ok=True)
    pdfs = args.dir / "pdfs"
    pdfs.mkdir(exist_ok=True)

    rows = [line.rstrip("\n").split("\t") for line in open(files_table(args.dir))]
    encrypted = [name for name, enc, _ in rows if enc == "t"]
    parsed = sum(1 for _, enc, status in rows if enc == "t" and status == "OK")
    print(f"{len(rows)} files; {len(encrypted)} encrypted ({100 * len(encrypted) / len(rows):.2f}%), "
          f"{parsed} of them parsed by Tika ({100 * parsed / len(encrypted):.1f}%)")

    rng = random.Random(args.seed)
    if args.plain:
        plain = [name for name, enc, _ in rows if enc == "f"]
        sample = sorted(rng.sample(plain, args.n))
        fetch(sample, pdfs)
        print(f"sample: {args.n} files Tika saw as not encrypted, seed {args.seed}, in {pdfs}")
        return
    sample = sorted(rng.sample(encrypted, args.n))
    fetch(sample, pdfs)
    status, handlers = census(pdfs, sample)
    print(f"sample: {args.n} encrypted files, seed {args.seed}")
    for k, v in status.most_common():
        print(f"  {k}: {v} ({100 * v / args.n:.1f}%)")
    opened = status["opens with the empty user password"]
    print("their handlers:")
    for k, v in handlers.most_common():
        print(f"  {k}: {v} ({100 * v / opened:.1f}%)")


if __name__ == "__main__":
    main()
