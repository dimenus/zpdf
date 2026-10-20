# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow==11.3.0", "pypng==0.20220715.0", "numpy"]
# ///
"""Draws every test image with zpdf, renders the PDF with MuPDF, and compares the pixels with
the image as decoders that share no code with zpdf read it.

    uv run tools/image-oracle.py [--exe zig-out/bin/zpdf-image] [--keep DIR] [images...]

With no images it takes tests/images/ (PngSuite, the Exif set, the JPEG set). Needs mutool.

For each image, zpdf-image writes a page the image's size as shown, one point per pixel, with
the image filling it, and `mutool draw -r 72` renders it on white, one pixel per image pixel.
The expected picture:
  PNG   pypng's asDirect (palette expanded, tRNS as alpha, at the file's depth), laid over white
        with its alpha in floating point, then turned by the eXIf orientation as Pillow's
        exif_transpose turns it.
  JPEG  Pillow's decode (libjpeg-turbo; MuPDF has its own libjpeg), turned by exif_transpose.
        Pillow reads a CMYK JPEG's samples as inverted, as Apple ImageIO and Chrome do.
A PNG passes when no channel of any pixel differs by more than 3. Rounding to 8 bits costs up to
2; PngSuite's 16-bit RGBA files (basn6a16 and the others) render up to 3 off although zpdf's
samples are the file's exactly, which the sample check below shows. A JPEG passes when the mean
difference is under 3 and none is over 40: two JPEG decoders differ by a few levels, and a
turned or mirrored picture differs by more than 100 on a large part of it. A CMYK JPEG's colours
depend on each program's CMYK to RGB conversion (MuPDF's is colour-managed, Pillow's is not), so
the question is only whether the render is Pillow's picture or its negative: it passes when their
brightness correlates by 0.5 or more. The right render correlates strongly positively and an
inverted one strongly negatively (see it by deleting the CMYK /Decode in src/pdf.zig); the
conversions differ most on the dark, saturated colours of cmyk-plain.jpg, which is still far
from the bound. tests/images/exif/
also has to render as one picture: its eight PNGs the same pixels, its eight JPEGs within the
JPEG bound of that.

A rendering is 8 bits, so it cannot see a 16-bit sample's low byte, and a palette drawn through
the wrong indices can still look close. So each PNG's PDF is also read back (mutool show) and
its samples compared exactly with pypng's `read`: the dimensions and bit depth, the colour
space (with the palette, entry by entry), the samples (palette indices for a palette image), the
soft mask's samples when the image has alpha that is not all opaque (none otherwise), and the
colour-key /Mask when it has a grey or RGB tRNS.

Refusals: PngSuite's x* files and any file named *-refused.* must be refused, every other file
drawn. Exit 1 when anything fails, or when no image was compared.
"""
import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import png
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parent.parent

# Pillow's exif_transpose methods (PIL/ImageOps.py), so a PNG decoded by pypng is turned as
# Pillow turns the JPEGs.
TURN = {
    2: Image.Transpose.FLIP_LEFT_RIGHT,
    3: Image.Transpose.ROTATE_180,
    4: Image.Transpose.FLIP_TOP_BOTTOM,
    5: Image.Transpose.TRANSPOSE,
    6: Image.Transpose.ROTATE_270,
    7: Image.Transpose.TRANSVERSE,
    8: Image.Transpose.ROTATE_90,
}


def expected_png(path: Path) -> np.ndarray:
    # asDirect: the palette expanded and tRNS made an alpha channel, at the file's bit depth
    # (or its sBIT depth). The blend over white is done once, in floating point, from those
    # samples, so the only rounding is the final one.
    w, h, rows, info = png.Reader(filename=str(path)).asDirect()
    planes = info["planes"]
    top = float(2 ** info["bitdepth"] - 1)
    px = np.array([list(r) for r in rows], dtype=np.float64).reshape(h, w, planes) / top
    color = px[:, :, :-1] if info["alpha"] else px
    a = px[:, :, -1:] if info["alpha"] else np.ones((h, w, 1))
    if info["greyscale"]:
        color = np.repeat(color, 3, axis=2)
    rgb = np.rint(255.0 * (color * a + (1.0 - a))).astype(np.uint8)
    tag = Image.open(path).getexif().get(0x0112, 1)
    img = Image.fromarray(rgb)
    if tag in TURN:
        img = img.transpose(TURN[tag])
    return np.asarray(img)


def expected_jpeg(path: Path) -> np.ndarray:
    return np.asarray(ImageOps.exif_transpose(Image.open(path)).convert("RGB"))


def mutool_show(args: list[str]) -> str:
    return subprocess.run(["mutool", "show", *args], check=True, capture_output=True, text=True).stdout


def stream_bytes(pdf: Path, num: int, work: Path) -> bytes:
    out = work / f"{pdf.stem}.{num}.bin"
    subprocess.run(["mutool", "show", "-b", "-o", str(out), str(pdf), str(num)], check=True)
    return out.read_bytes()


def unpack(data: bytes, w: int, h: int, n: int, depth: int) -> np.ndarray | None:
    stride = (w * n * depth + 7) // 8
    if len(data) != stride * h:
        return None
    rows = np.frombuffer(data, dtype=np.uint8).reshape(h, stride)
    if depth == 16:
        vals = rows.view(">u2").astype(np.int64)
    elif depth == 8:
        vals = rows[:, : w * n].astype(np.int64)
    else:
        bits = np.unpackbits(rows, axis=1)[:, : w * n * depth].reshape(h, w * n, depth).astype(np.int64)
        vals = (bits * (2 ** np.arange(depth - 1, -1, -1))).sum(axis=2)
    return vals.reshape(h, w, n)


def check_png_samples(image: Path, pdf: Path, work: Path) -> list[str]:
    w, h, rows, info = png.Reader(filename=str(image)).read()
    planes, depth = info["planes"], info["bitdepth"]
    raw = np.array([list(r) for r in rows], dtype=np.int64).reshape(h, w, planes)
    page = re.search(r"page 1 = (\d+) 0 R", mutool_show([str(pdf), "pages"]))
    xobjects = re.findall(r"/X\d+ (\d+) 0 R", mutool_show(["-g", str(pdf), page.group(1)]))
    if len(xobjects) != 1:
        return [f"{image}: the page has {len(xobjects)} XObjects, not 1"]
    num = int(xobjects[0])
    d = mutool_show(["-g", str(pdf), str(num)]).split(">> stream")[0]
    bad: list[str] = []

    def entry(pattern: str) -> re.Match | None:
        return re.search(pattern, d)

    for key, want in (("Width", w), ("Height", h), ("BitsPerComponent", depth)):
        m = entry(rf"/{key} (\d+)")
        if not m or int(m.group(1)) != want:
            bad.append(f"/{key} is {m.group(1) if m else 'missing'}, the file says {want}")
    data = stream_bytes(pdf, num, work)
    smask = entry(r"/SMask (\d+) 0 R")
    mask_samples = None
    # pypng also gives "palette" for a truecolour file with a suggested PLTE (pp0n2c16); only a
    # one-plane colour file is a palette image.
    if "palette" in info and planes == 1 and not info["greyscale"]:
        palette = info["palette"]
        cs = entry(r"/ColorSpace\[/Indexed/DeviceRGB (\d+)<([0-9A-F]+)>\]")
        want_hex = "".join(f"{c:02X}" for p in palette for c in p[:3])
        if not cs or int(cs.group(1)) != len(palette) - 1 or cs.group(2) != want_hex:
            bad.append("the /Indexed palette is not the file's PLTE")
        got = unpack(data, w, h, 1, depth)
        if got is None or not np.array_equal(got, raw):
            bad.append("the palette indices differ from the file's")
        alphas = np.array([p[3] if len(p) == 4 else 255 for p in palette])
        a = alphas[raw[:, :, 0]]
        if (a != 255).any():
            mask_samples = (a.reshape(h, w, 1), 8)
    else:
        n = planes - (1 if info["alpha"] else 0)
        cs = "/DeviceGray" if n == 1 else "/DeviceRGB"
        if not entry(rf"/ColorSpace{cs}\b"):
            bad.append(f"the colour space is not {cs}")
        got = unpack(data, w, h, n, depth)
        if got is None or not np.array_equal(got, raw[:, :, :n]):
            bad.append("the colour samples differ from the file's")
        if info["alpha"] and (raw[:, :, -1] != 2**depth - 1).any():
            mask_samples = (raw[:, :, -1:], depth)
        key = info.get("transparent")
        if key is not None:
            values = [key] if isinstance(key, int) else list(key)
            want_mask = " ".join(f"{v} {v}" for v in values)
            m = entry(r"/Mask\[([0-9 ]+)\]")
            if not m or m.group(1) != want_mask:
                bad.append(f"/Mask is {m.group(1) if m else 'missing'}, the tRNS says [{want_mask}]")
        elif entry(r"/Mask\["):
            bad.append("a /Mask, but the file has no tRNS")
    if mask_samples is None:
        if smask:
            bad.append("an /SMask, but every pixel is opaque")
    elif not smask:
        bad.append("no /SMask, but the image has alpha")
    else:
        want_a, a_depth = mask_samples
        got = unpack(stream_bytes(pdf, int(smask.group(1)), work), w, h, 1, a_depth)
        if got is None or not np.array_equal(got, want_a):
            bad.append("the soft mask's samples differ from the file's alpha")
    return [f"{image}: {b}" for b in bad]


def render(exe: Path, image: Path, work: Path) -> tuple[np.ndarray | None, str]:
    pdf = work / (image.stem + ".pdf")
    out = work / (image.stem + ".render.png")
    r = subprocess.run([str(exe), str(image), str(pdf)], capture_output=True, text=True)
    if r.returncode == 1:
        return None, r.stderr.strip()
    if r.returncode != 0:
        raise SystemExit(f"{image}: zpdf-image exited {r.returncode}: {r.stderr.strip()}")
    subprocess.run(["mutool", "draw", "-q", "-r", "72", "-c", "rgb", "-o", str(out), str(pdf)], check=True)
    return np.asarray(Image.open(out).convert("RGB")), str(pdf)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--exe", type=Path, default=ROOT / "zig-out" / "bin" / "zpdf-image")
    ap.add_argument("--keep", type=Path, help="keep the PDFs and renders here")
    ap.add_argument("images", nargs="*", type=Path)
    args = ap.parse_args()
    images = args.images or sorted(
        p for p in (ROOT / "tests" / "images").rglob("*") if p.suffix.lower() in (".png", ".jpg", ".jpeg")
    )
    work = args.keep or Path(tempfile.mkdtemp(prefix="image-oracle-"))
    work.mkdir(parents=True, exist_ok=True)

    failures: list[str] = []
    compared = refused = samples_checked = 0
    exif_renders: dict[str, np.ndarray] = {}
    for image in images:
        must_refuse = image.stem.endswith("-refused") or (image.parent.name == "pngsuite" and image.name.startswith("x"))
        got, err_or_pdf = render(args.exe, image, work)
        err = err_or_pdf
        if got is None:
            if must_refuse:
                refused += 1
            else:
                failures.append(f"{image}: refused ({err})")
            continue
        if must_refuse:
            failures.append(f"{image}: drawn, but must be refused")
            continue
        is_png = image.suffix.lower() == ".png"
        want = expected_png(image) if is_png else expected_jpeg(image)
        compared += 1
        if got.shape != want.shape:
            failures.append(f"{image}: rendered {got.shape[1]}x{got.shape[0]}, expected {want.shape[1]}x{want.shape[0]}")
            continue
        diff = np.abs(got.astype(np.int16) - want.astype(np.int16))
        worst, mean = int(diff.max()), float(diff.mean())
        if not is_png and Image.open(image).mode == "CMYK":
            r = float(np.corrcoef(got.mean(axis=2).ravel(), want.mean(axis=2).ravel())[0, 1])
            ok = r >= 0.5
            if not ok:
                failures.append(f"{image}: CMYK brightness correlates {r:.3f} with Pillow's")
            print(f"{'ok  ' if ok else 'FAIL'} {image.relative_to(ROOT) if image.is_relative_to(ROOT) else image}: CMYK, correlation {r:.3f}")
            continue
        ok = worst <= 3 if is_png else (mean < 3 and worst <= 40)
        if not ok:
            failures.append(f"{image}: max {worst}, mean {mean:.2f}")
        if is_png:
            sample_failures = check_png_samples(image, Path(err_or_pdf), work)
            samples_checked += 1
            ok = ok and not sample_failures
            failures.extend(sample_failures)
        if image.parent.name == "exif":
            exif_renders[image.name] = got
        print(f"{'ok  ' if ok else 'FAIL'} {image.relative_to(ROOT) if image.is_relative_to(ROOT) else image}: max {worst}, mean {mean:.2f}")

    if exif_renders:
        first = exif_renders.get("orient-1.png")
        if first is None:
            failures.append("tests/images/exif: orient-1.png was not rendered")
        else:
            for name, got in sorted(exif_renders.items()):
                if got.shape != first.shape:
                    failures.append(f"exif/{name}: {got.shape[1]}x{got.shape[0]}, orient-1.png is {first.shape[1]}x{first.shape[0]}")
                    continue
                diff = np.abs(got.astype(np.int16) - first.astype(np.int16))
                same = diff.max() == 0 if name.endswith(".png") else (diff.mean() < 3 and diff.max() <= 40)
                if not same:
                    failures.append(f"exif/{name}: not the picture orient-1.png shows (max {diff.max()}, mean {diff.mean():.2f})")

    print(f"\n{compared} compared ({samples_checked} PNGs sample by sample), {refused} refused as expected, {len(failures)} failed")
    for f in failures:
        print("FAIL " + f)
    if compared == 0:
        print("no image was compared")
        return 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
