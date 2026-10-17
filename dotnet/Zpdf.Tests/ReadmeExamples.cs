using System;
using System.IO;
using System.IO.Pipelines;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Zpdf.Tests;

// README.md's C# examples, compiled and run. Each block between "// readme: <name>" and
// "// readme: end" must equal README.md's block after "<!-- example: <name> -->", once dedented;
// `zig build test` checks that (tools/readme-examples.zig), so the README cannot show code that
// does not build.
public sealed class ReadmeExamples
{
    [Fact]
    public async Task The_write_and_read_examples_work_as_shown()
    {
        var output = new MemoryStream();

        // readme: write
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
        // readme: end

        var bytes = output.ToArray();
        var text = new StringWriter();
        var console = Console.Out;
        Console.SetOut(text);
        try
        {
            // readme: read
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
            // readme: end
        }
        finally
        {
            Console.SetOut(console);
        }

        Assert.Equal(
            ["page 1: 612 x 792 pt", "  at (72, 720), Helvetica 24 pt: Hello from zpdf"],
            text.ToString().Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries).ToArray());
    }
}
