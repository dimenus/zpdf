# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow==11.3.0", "simplejpeg==1.9.0", "numpy"]
# ///
"""Rebuilds tests/images/exif/ and tests/images/jpeg/, the images zpdf's image tests read, with
Pillow, so they come from another writer than zpdf.

    uv run tools/image-fixtures.py        (from the repo root)

tests/images/exif/: one picture stored eight ways, each with the Exif orientation (1 to 8) that
turns it back upright, as orient-N.jpg and orient-N.png (the PNG's tag in an eXIf chunk). Shown as
the tag says, all sixteen are the same picture, so a renderer that turns any one wrongly shows a
different picture from the other fifteen (tools/image-oracle.py checks that, besides comparing
each one with Pillow's own exif_transpose).

tests/images/jpeg/: the JPEG kinds addImage takes: gray, progressive, and three CMYK files. JPEG
viewers (Pillow, Apple ImageIO, Chrome) read every CMYK JPEG's samples as inverted, with an Adobe
APP14 marker or without, so zpdf must show each of these as they do:
  cmyk.jpg          Pillow: inverted samples, APP14 transform 0 (shows right)
  cmyk-noadobe.jpg  the same with its APP14 removed (shows right)
  cmyk-plain.jpg    TurboJPEG given samples that are not inverted, APP14 transform 2: every
                    viewer shows it as a negative, so zpdf's PDF must too

tests/images/png/: alpha that is partial everywhere and never 0, as RGBA and as a palette with
tRNS. Every PngSuite file with alpha has some fully transparent pixel, so without these a writer
that drops the soft mask whenever no pixel is 0 passes (found by mutation, 2026-10-20).

The picture is 32 x 16, not square, and no turn or mirror of it is itself: a red block at the top
left and a blue bar along the bottom of a white-to-green gradient. JPEG is saved at quality 95
without chroma subsampling, so two decoders differ by a few levels, not by blocks.
"""
from pathlib import Path

import numpy as np
import simplejpeg
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent / "tests" / "images"

# Pillow's ImageOps.exif_transpose turns tag N with this method; storing the picture with the
# inverse method makes tag N show it upright again.
SHOW = {
    2: Image.Transpose.FLIP_LEFT_RIGHT,
    3: Image.Transpose.ROTATE_180,
    4: Image.Transpose.FLIP_TOP_BOTTOM,
    5: Image.Transpose.TRANSPOSE,
    6: Image.Transpose.ROTATE_270,
    7: Image.Transpose.TRANSVERSE,
    8: Image.Transpose.ROTATE_90,
}
INVERSE = {
    Image.Transpose.FLIP_LEFT_RIGHT: Image.Transpose.FLIP_LEFT_RIGHT,
    Image.Transpose.ROTATE_180: Image.Transpose.ROTATE_180,
    Image.Transpose.FLIP_TOP_BOTTOM: Image.Transpose.FLIP_TOP_BOTTOM,
    Image.Transpose.TRANSPOSE: Image.Transpose.TRANSPOSE,
    Image.Transpose.ROTATE_270: Image.Transpose.ROTATE_90,
    Image.Transpose.TRANSVERSE: Image.Transpose.TRANSVERSE,
    Image.Transpose.ROTATE_90: Image.Transpose.ROTATE_270,
}


def without_adobe(jpeg: bytes) -> bytes:
    """`jpeg` with its Adobe APP14 segment removed."""
    pos = 2
    while jpeg[pos + 1] != 0xDA:
        end = pos + 2 + int.from_bytes(jpeg[pos + 2:pos + 4], "big")
        if jpeg[pos + 1] == 0xEE and jpeg[pos + 4:pos + 9] == b"Adobe":
            return jpeg[:pos] + jpeg[end:]
        pos = end
    raise SystemExit("no APP14 segment")


def picture() -> Image.Image:
    img = Image.new("RGB", (32, 16))
    for x in range(32):
        for y in range(16):
            img.putpixel((x, y), (255 - 8 * x, 255, 255 - 8 * x))
    for x in range(8):
        for y in range(8):
            img.putpixel((x, y), (220, 0, 0))
    for x in range(32):
        for y in range(12, 16):
            img.putpixel((x, y), (0, 0, 200))
    return img


def main() -> None:
    base = picture()
    exif_dir = ROOT / "exif"
    exif_dir.mkdir(parents=True, exist_ok=True)
    for tag in range(1, 9):
        stored = base if tag == 1 else base.transpose(INVERSE[SHOW[tag]])
        exif = Image.Exif()
        exif[0x0112] = tag
        stored.save(exif_dir / f"orient-{tag}.jpg", quality=95, subsampling=0, exif=exif)
        stored.save(exif_dir / f"orient-{tag}.png", exif=exif)

    jpeg_dir = ROOT / "jpeg"
    jpeg_dir.mkdir(parents=True, exist_ok=True)
    base.convert("L").save(jpeg_dir / "gray.jpg", quality=95)
    base.save(jpeg_dir / "progressive.jpg", quality=95, subsampling=0, progressive=True)
    (jpeg_dir / "cmyk-refused.jpg").unlink(missing_ok=True)
    base.convert("CMYK").save(jpeg_dir / "cmyk.jpg", quality=95)
    (jpeg_dir / "cmyk-noadobe.jpg").write_bytes(without_adobe((jpeg_dir / "cmyk.jpg").read_bytes()))
    # K stored as 255, which a viewer reads as no black ink, so the negative keeps the picture's
    # shape (Pillow's conversion has K = 0, which read inverted is solid black).
    plain = np.array(base.convert("CMYK"))
    plain[:, :, 3] = 255
    (jpeg_dir / "cmyk-plain.jpg").write_bytes(simplejpeg.encode_jpeg(plain, quality=95, colorspace="CMYK"))
    png_dir = ROOT / "png"
    png_dir.mkdir(parents=True, exist_ok=True)
    half = base.convert("RGBA")
    half.putalpha(128)
    half.save(png_dir / "half-alpha.png")
    palette = base.quantize(colors=16)
    palette.save(png_dir / "half-alpha-palette.png", transparency=bytes([128] * 16))
    for p in sorted(exif_dir.iterdir()) + sorted(jpeg_dir.iterdir()) + sorted(png_dir.iterdir()):
        print(p.relative_to(ROOT.parent.parent), p.stat().st_size)


if __name__ == "__main__":
    main()
