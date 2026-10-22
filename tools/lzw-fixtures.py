# /// script
# requires-python = ">=3.11"
# ///
"""Writes tests/read/lzw/, the LZWDecode data src/read.zig's tests decode: base.pdf's bytes
encoded twice, so each must decode to tests/read/base.pdf.

    uv run tools/lzw-fixtures.py        (from the repo root; needs tiffcp from libtiff, and qpdf)

- early-change-1.lzw: written by libtiff (tiffcp -c lzw), an encoder that shares no code with
  zpdf. TIFF's LZW is the PDF one with /EarlyChange 1, the default.
- early-change-0.lzw: /EarlyChange 0, which libtiff cannot write, from the encoder below.

base.pdf is mostly compressed data, so both fill the code table and clear it more than once. Each
file is checked before it is kept: qpdf must decode it, as a stream in a PDF, to base.pdf's bytes.
"""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def tiff(width: int, data: bytes) -> bytes:
    """An uncompressed 8-bit grey TIFF, one row of `width` pixels, little-endian."""
    entries = [
        (256, 4, width),  # ImageWidth
        (257, 4, 1),  # ImageLength
        (258, 3, 8),  # BitsPerSample
        (259, 3, 1),  # Compression: none
        (262, 3, 1),  # PhotometricInterpretation: black is zero
        (273, 4, 0),  # StripOffsets, set below
        (277, 3, 1),  # SamplesPerPixel
        (278, 4, 1),  # RowsPerStrip
        (279, 4, len(data)),  # StripByteCounts
    ]
    ifd_at = 8
    data_at = ifd_at + 2 + 12 * len(entries) + 4
    entries[5] = (273, 4, data_at)
    out = bytearray(b"II*\0" + struct.pack("<I", ifd_at) + struct.pack("<H", len(entries)))
    for tag, kind, value in entries:
        out += struct.pack("<HHI", tag, kind, 1)
        out += struct.pack("<I", value) if kind == 4 else struct.pack("<HH", value, 0)
    out += struct.pack("<I", 0)
    return bytes(out) + data


def tiff_strip(t: bytes) -> bytes:
    """The one strip of a little-endian, single-strip TIFF."""
    assert t[:4] == b"II*\0", "tiffcp wrote a big-endian TIFF"
    (ifd_at,) = struct.unpack_from("<I", t, 4)
    (count,) = struct.unpack_from("<H", t, ifd_at)
    tags = {}
    for i in range(count):
        tag, kind, n, value = struct.unpack_from("<HHII", t, ifd_at + 2 + 12 * i)
        if kind == 3:
            value &= 0xFFFF
        tags[tag] = (n, value)
    assert tags[259] == (1, 5), f"not LZW: {tags[259]}"
    assert tags[273][0] == 1 and tags[279][0] == 1, "more than one strip"
    assert tags.get(317, (1, 1))[1] == 1, "a predictor was applied"
    return t[tags[273][1] : tags[273][1] + tags[279][1]]


def encode(data: bytes, early_change: int) -> bytes:
    """LZW as ISO 32000-1 7.4.4.2 describes it. The code width follows the decoder's table: it
    adds one entry for each code after the first since a clear, and widens the code when the next
    entry needs it (one entry early with early_change 1). The table is cleared before it overflows
    4096 entries."""
    out = bytearray()
    acc = 0
    held = 0

    def put(code: int, bits: int) -> None:
        nonlocal acc, held
        acc = acc << bits | code
        held += bits
        while held >= 8:
            held -= 8
            out.append(acc >> held & 0xFF)

    bits = 9
    table: dict[bytes, int] = {}
    emitted = 0

    def clear() -> None:
        nonlocal bits, emitted
        put(256, bits)
        table.clear()
        table.update({bytes([i]): i for i in range(256)})
        bits = 9
        emitted = 0

    def emit(code: int) -> None:
        nonlocal bits, emitted
        put(code, bits)
        emitted += 1
        decoder_next = 258 + emitted - 1
        if bits < 12 and decoder_next + early_change >= 1 << bits:
            bits += 1

    clear()
    w = b""
    for c in data:
        wc = w + bytes([c])
        if wc in table:
            w = wc
            continue
        emit(table[w])
        entry = 258 + emitted - 1
        if entry == 4096:
            clear()
        else:
            table[wc] = entry
        w = bytes([c])
    if w:
        emit(table[w])
    put(257, bits)
    if held:
        out.append(acc << (8 - held) & 0xFF)
    return bytes(out)


def qpdf_decode(lzw: bytes, early_change: int, tmp: Path) -> bytes:
    """`lzw` decoded by qpdf, as the one stream in a minimal PDF."""
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [] /Count 0 >>",
        b"<< /Length %d /Filter /LZWDecode /DecodeParms << /EarlyChange %d >> >>\nstream\n"
        % (len(lzw), early_change)
        + lzw
        + b"\nendstream",
    ]
    pdf = bytearray(b"%PDF-1.7\n")
    offsets = []
    for i, body in enumerate(objs, 1):
        offsets.append(len(pdf))
        pdf += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(pdf)
    pdf += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for off in offsets:
        pdf += b"%010d 00000 n \n" % off
    pdf += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    path = tmp / "check.pdf"
    path.write_bytes(pdf)
    r = subprocess.run(["qpdf", "--show-object=3", "--filtered-stream-data", str(path)], capture_output=True)
    if r.returncode != 0:
        sys.exit(f"qpdf could not decode it: {r.stderr.decode()}")
    return r.stdout


def main() -> None:
    plain = Path("tests/read/base.pdf").read_bytes()
    out = Path("tests/read/lzw")
    out.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        (tmp / "in.tif").write_bytes(tiff(len(plain), plain))
        subprocess.run(["tiffcp", "-c", "lzw", str(tmp / "in.tif"), str(tmp / "out.tif")], check=True)
        files = {
            1: tiff_strip((tmp / "out.tif").read_bytes()),
            0: encode(plain, 0),
        }
        for early_change, lzw in files.items():
            if qpdf_decode(lzw, early_change, tmp) != plain:
                sys.exit(f"qpdf decodes early-change-{early_change}.lzw to something other than base.pdf")
            (out / f"early-change-{early_change}.lzw").write_bytes(lzw)
            print(f"early-change-{early_change}.lzw: {len(lzw)} bytes, qpdf decodes it to base.pdf")


if __name__ == "__main__":
    main()
