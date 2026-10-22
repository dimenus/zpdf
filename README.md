# zpdf

zpdf writes PDFs and reads the text back out of them. It's written in Zig, and one C ABI serves
the browser (WebAssembly), C and .NET.

## What it does

Writing:
- Real fonts. TrueType and OpenType, shaped with [kb_text_shape](https://github.com/JimmyLefevre/kb),
  so Arabic, Hebrew, Devanagari and other complex scripts are shaped too. Fonts get embedded as
  subsets, and the text stays copyable and searchable.
- The 14 standard PDF fonts, when you don't want to embed anything.
- Lines, rectangles, and text you fill in later, like "Page 3 of 12".
- JPEG and PNG images. A JPEG goes in as it is; a PNG is decoded and checked, and its transparency
  is kept. A photo's Exif orientation is applied. Each image is in the file once, however many
  pages draw it.
- Links, to a web address or to a place on any page (a later one too), and bookmarks in a tree.
- Pages go out as they end. Memory follows one page, not the whole document.

Reading:
- Page count, page boxes and rotation, and the text each page draws as positioned runs, one page
  at a time. Encrypted files open when they need no password, as most do (RC4 and AES, every
  revision of the standard security handler). One that needs a password is refused, except in
  Zig, where the reader takes one.

It's early (0.x). The C ABI has a version number, and it changes whenever the ABI does.

## .NET

```
dotnet add package Zpdf
```

.NET 10 on linux-x64, linux-arm64, osx-arm64 and win-x64. The native library for each one ships
in the package.

Write a PDF into any Stream, like a file or an HTTP response body. zpdf writes each page straight
into the pipe's memory, so there's no extra copy, and the flush after each page is where the I/O
waits:

<!-- example: write -->
```csharp
var pipe = PipeWriter.Create(output);
using (var pdf = PdfWriter.Create(pipe, compress: true))
{
    var helvetica = pdf.AddStandardFont(StandardFont.Helvetica);
    var page = pdf.BeginPage(612, 792);
    pdf.DrawText(page, helvetica, 24, 72, 720, PdfColor.Black, "Hello from zpdf", TextDirection.FromText);
    pdf.EndPage(page);
    await PdfWriter.FlushAsync(pipe, CancellationToken.None);
    pdf.Finish();
    await PdfWriter.FlushAsync(pipe, CancellationToken.None);
}
await pipe.CompleteAsync();
```

Read it back:

<!-- example: read -->
```csharp
using var reader = PdfReader.Open(bytes);
for (var i = 0; i < reader.PageCount; i++)
{
    var box = reader.GetPage(i).MediaBox;
    Console.WriteLine($"page {i + 1}: {box.Width} x {box.Height} pt");
    foreach (var run in reader.ReadText(i).Runs)
    {
        Console.WriteLine($"  at ({run.X}, {run.Y}), {run.Font} {run.Size} pt: {run.Text}");
    }
}
```

Measure and wrap text with the same widths the writer draws. `Wrap` breaks at spaces and around
CJK, keeps line breaks, and with `breakWords` splits a word that is too long for the line. Lines
come back as offsets into your string, in a list you can reuse:

<!-- example: wrap -->
```csharp
using var helvetica = FontMetrics.Open(StandardFont.Helvetica);
var cell = "Cost of goods on hand, by location";
var lines = new List<TextLine>();
helvetica.Wrap(cell, 10, 100, breakWords: true, TextDirection.FromText, lines);
foreach (var line in lines)
{
    Console.WriteLine($"{cell.Substring(line.Start, line.Length)} ({line.Width:0.##} pt)");
}
```

Units are points (1/72 inch), and y goes up from the bottom of the page. `PdfWriter` takes any
`IBufferWriter<byte>`, and `AddFont` embeds a font file. The source in [dotnet/Zpdf](dotnet/Zpdf)
documents both.

## Zig

```
zig fetch --save git+https://github.com/dimenus/zpdf
```

That pins the current commit in your `build.zig.zon`. Then import the module in `build.zig`:

<!-- example: zig-build -->
```zig
const zpdf = b.dependency("zpdf", .{ .target = target, .optimize = optimize });
const exe = b.addExecutable(.{ .name = "hello", .root_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "zpdf", .module = zpdf.module("zpdf") }},
}) });
```

And write a PDF with it:

<!-- example: zig-main -->
```zig
var out: std.Io.Writer.Allocating = .init(gpa);
defer out.deinit();

var doc = try zpdf.Document.begin(gpa, &out.writer, .{ .compress = true });
defer doc.deinit();
const helvetica = try doc.addStandardFont(.helvetica);
const page = try doc.beginPage(612, 792);
try doc.drawText(page, helvetica, 24, 72, 720, .black, "Hello from zpdf", .{});
try doc.endPage(page);
try doc.finish();
```

`Document` writes into any `std.Io.Writer`, so a file or a socket works as well as memory. You get
just the library: zpdf's tests and tools stay out of your build.

## C

```
tools/zig build abi
```

You get the shared library (`zig-out/lib`, or `zig-out/bin` on Windows) and `zpdf.h` in
`zig-out/include`. The comments in the header are the protocol: contexts, handles, buffers and
error codes.

## Browser

```
tools/zig build wasm
```

That builds `zig-out/bin/zpdf.wasm`. [web/zpdf.js](web/zpdf.js) is a thin wrapper around it.

## Building

Use the Zig version in `build.zig.zon`. `tools/zig` picks it for you through
[mise](https://mise.jdx.dev); if that version is already on your PATH, plain `zig` is fine.

```
tools/zig build test          # unit tests, golden PDFs, the C ABI, the wasm build
tools/zig build dotnet-test   # the .NET library (needs the .NET 10 SDK)
```

[AGENTS.md](AGENTS.md) has the rest: valgrind, benchmarks, browser tests and mutation testing.

## License

zlib, see [LICENSE](LICENSE). kb_text_shape is zlib too. The library also holds Adobe's standard-font
metrics, glyph names and CJK character maps; their notices are in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md), which ships in every package.
