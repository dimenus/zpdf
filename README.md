# zpdf

A PDF writer and text reader written in Zig, with one C ABI that the browser (WebAssembly), C and
.NET all use.

**Writing**
- TrueType and OpenType fonts, shaped with [kb_text_shape](https://github.com/JimmyLefevre/kb),
  including complex scripts such as Arabic, Hebrew and Devanagari. Each font is embedded as a
  subset, and its text can be copied and searched.
- The 14 standard PDF fonts, which need no embedding.
- Lines, filled and stroked rectangles, and text placed later, such as "Page 3 of 12".
- Each page is written when it ends, so memory follows one page, not the whole document.

**Reading**
- The page count, each page's boxes and rotation, and the text each page draws, as positioned runs,
  one page at a time. Encrypted files are refused.

zpdf is young (0.x). Its C ABI carries a version number, which changes whenever the ABI does.

## .NET

```
dotnet add package Zpdf
```

.NET 10, on linux-x64, linux-arm64, osx-arm64 and win-x64. The package carries the native library
for each.

Write a PDF into any `Stream` (a file, an HTTP response body). zpdf writes each page straight into
the pipe's memory, and the flush after each page is where the I/O waits:

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

Read its pages and text back:

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

Units are points (1/72 inch), with y going up from the bottom of the page. `PdfWriter` takes any
`IBufferWriter<byte>`; `AddFont` embeds a font file. Both types are documented in their source,
in [dotnet/Zpdf](dotnet/Zpdf).

## C

```
tools/zig build abi
```

This installs the shared library (in `zig-out/lib`, or `zig-out/bin` on Windows) and its header,
`zig-out/include/zpdf.h`. The header's comments are the protocol: contexts, handles, buffers and
error codes.

## In the browser

```
tools/zig build wasm
```

This builds `zig-out/bin/zpdf.wasm`. [web/zpdf.js](web/zpdf.js) is a small JavaScript wrapper
for it.

## Building and testing

zpdf builds with the Zig version named in `build.zig.zon`. `tools/zig` runs that version through
[mise](https://mise.jdx.dev); with that version on your PATH, plain `zig` works too.

```
tools/zig build test          # unit tests, golden PDFs, the C ABI, the wasm build
tools/zig build dotnet-test   # the .NET library (needs the .NET 10 SDK)
```

[AGENTS.md](AGENTS.md) lists the other checks: valgrind, benchmarks, browser tests and mutation
testing.

## License

zlib; see [LICENSE](LICENSE). kb_text_shape, which zpdf builds in, is also under the zlib license.
