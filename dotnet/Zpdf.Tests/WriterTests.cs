using System;
using System.Buffers;
using System.IO;
using System.IO.Pipelines;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using Zpdf.Native;

namespace Zpdf.Tests;

public sealed class WriterTests
{
    private const int Pages = 20;
    private const int LinesPerPage = 40;

    // The test document's lines, made once, so drawing a page allocates nothing of the test's own.
    private static readonly string[] Lines = Enumerable.Range(0, Pages * LinesPerPage)
        .Select(i => $"page {i / LinesPerPage} line {i % LinesPerPage} async office")
        .ToArray();

    private static byte[] TestFont() =>
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "TestFont.ttf"));

    // Draws page `index` of the test document: 40 lines of Helvetica.
    private static PageId DrawPage(PdfWriter writer, FontId font, int index)
    {
        var page = writer.BeginPage(612, 792);
        for (var l = 0; l < LinesPerPage; l++)
        {
            writer.DrawText(page, font, 10, 36, 760 - l * 14, PdfColor.Black, Lines[index * LinesPerPage + l], TextDirection.FromText);
        }
        return page;
    }

    // The same document from zpdf's buffered writer, through the raw ABI with no PdfWriter and no
    // sink: what every sink path must equal.
    private static unsafe byte[] Reference()
    {
        // The library's own entry points register its resolver; this test calls the ABI directly.
        ZpdfLibrary.EnsureLoaded();
        var context = ZpdfAbi.zpdf_context_new();
        try
        {
            uint doc;
            uint standard;
            uint font;
            ZpdfLibrary.Check(ZpdfAbi.zpdf_doc_new(context, 1, &doc));
            ZpdfLibrary.Check(ZpdfAbi.zpdf_font_open_standard(context, (uint)StandardFont.Helvetica, &standard));
            ZpdfLibrary.Check(ZpdfAbi.zpdf_doc_add_font(context, doc, standard, &font));
            for (var p = 0; p < Pages; p++)
            {
                uint page;
                ZpdfLibrary.Check(ZpdfAbi.zpdf_doc_begin_page(context, doc, 612, 792, &page));
                for (var l = 0; l < LinesPerPage; l++)
                {
                    var line = System.Text.Encoding.UTF8.GetBytes(Lines[p * LinesPerPage + l]);
                    fixed (byte* text = line)
                    {
                        ZpdfLibrary.Check(ZpdfAbi.zpdf_doc_draw_text(context, doc, page, font, 10, 36, 760 - l * 14, 0, 0, 0, text, (nuint)line.Length, 0));
                    }
                }
                ZpdfLibrary.Check(ZpdfAbi.zpdf_doc_end_page(context, doc, page));
            }
            byte* pdf;
            nuint length;
            ZpdfLibrary.Check(ZpdfAbi.zpdf_doc_finish(context, doc, &pdf, &length));
            var bytes = new ReadOnlySpan<byte>(pdf, checked((int)length)).ToArray();
            ZpdfLibrary.Check(ZpdfAbi.zpdf_free(context, pdf, length));
            return bytes;
        }
        finally
        {
            ZpdfLibrary.Check(ZpdfAbi.zpdf_context_free(context));
        }
    }

    // Writes the test document into `output`, awaiting `flush` after each page and after Finish.
    // `drawn` counts pages drawn.
    private static async Task RenderAsync(IBufferWriter<byte> output, Func<ValueTask> flush, StrongBox<int>? drawn)
    {
        using var writer = PdfWriter.Create(output, compress: true);
        var font = writer.AddStandardFont(StandardFont.Helvetica);
        for (var p = 0; p < Pages; p++)
        {
            writer.EndPage(DrawPage(writer, font, p));
            Assert.False(writer.Lent, "zpdf held the output's memory after EndPage returned");
            if (drawn != null)
            {
                drawn.Value++;
            }
            await flush();
        }
        writer.Finish();
        Assert.False(writer.Lent, "zpdf held the output's memory after Finish returned");
        await flush();
    }

    [Fact]
    public void Zpdf_writes_into_the_outputs_memory_with_no_managed_allocation_or_copy()
    {
        var want = Reference();

        // The base rate, so the counter is shown to see allocations: an ArrayBufferWriter grows by
        // allocating a larger array and copying into it.
        var growing = new ArrayBufferWriter<byte>(1);
        var growing_allocated = AllocatedWhileWriting(growing);
        Assert.Equal(want, growing.WrittenSpan.ToArray());
        Assert.True(growing_allocated > want.Length, $"the counter saw {growing_allocated} bytes on the growing path; it must see the growth for this test to mean anything");

        // One preallocated array: zpdf's writes land in it through GetMemory and Advance, and
        // drawing, ending pages and finishing allocate nothing.
        var target = new CountingBufferWriter(want.Length + 64 * 1024);
        var allocated = AllocatedWhileWriting(target);
        Assert.Equal(want, target.Written.ToArray());
        // Every byte arrives once, by Advance into the output's own memory: no copy of it is made
        // anywhere the output can see.
        Assert.Equal(want.Length, target.Advanced);
        Assert.InRange(target.GetMemoryCalls, 1, Pages * 4 + 4);
        Assert.Equal(0, allocated);
    }

    // The managed bytes this thread allocates from the first page to Finish.
    private static long AllocatedWhileWriting(IBufferWriter<byte> output)
    {
        using var writer = PdfWriter.Create(output, compress: true);
        var font = writer.AddStandardFont(StandardFont.Helvetica);
        var before = GC.GetAllocatedBytesForCurrentThread();
        for (var p = 0; p < Pages; p++)
        {
            writer.EndPage(DrawPage(writer, font, p));
        }
        writer.Finish();
        return GC.GetAllocatedBytesForCurrentThread() - before;
    }

    [Fact]
    public async Task A_stream_and_a_pipe_get_the_reference_bytes()
    {
        var want = Reference();

        var stream = new MemoryStream();
        var to_stream = PipeWriter.Create(stream, new StreamPipeWriterOptions(leaveOpen: true));
        await RenderAsync(to_stream, () => PdfWriter.FlushAsync(to_stream, CancellationToken.None), null);
        await to_stream.CompleteAsync();
        Assert.Equal(want, stream.ToArray());

        var pipe = new Pipe();
        var read = ReadAllAsync(pipe.Reader, TimeSpan.Zero);
        await RenderAsync(pipe.Writer, () => PdfWriter.FlushAsync(pipe.Writer, CancellationToken.None), null);
        await pipe.Writer.CompleteAsync();
        var (got, _) = await read;
        Assert.Equal(want, got);
    }

    [Fact]
    public async Task A_pages_flush_is_awaited_not_blocked_on_and_the_next_page_waits_for_it()
    {
        var want = Reference();
        var stream = new GatedStream();
        var output = PipeWriter.Create(stream, new StreamPipeWriterOptions(leaveOpen: true));
        var drawn = new StrongBox<int>(0);
        var render = RenderAsync(output, () => PdfWriter.FlushAsync(output, CancellationToken.None), drawn);
        for (var p = 0; p < Pages; p++)
        {
            await Until(stream.NextFlush(), render);
            // The page's flush is pending: rendering waits for it without blocking this thread,
            // and has not drawn the next page.
            Assert.False(render.IsCompleted, $"page {p}: the render finished while a flush was pending");
            Assert.Equal(p + 1, drawn.Value);
            stream.Release();
        }
        await Until(stream.NextFlush(), render);
        stream.Release();
        await render;
        await output.CompleteAsync();
        Assert.Equal(want, stream.ToArray());
    }

    [Fact]
    public async Task A_slow_reader_holds_the_writer_to_one_page_plus_the_pipes_threshold()
    {
        var want = Reference();
        const int threshold = 256;
        var pipe = new Pipe(new PipeOptions(pauseWriterThreshold: threshold, resumeWriterThreshold: threshold / 2));
        var read = ReadAllAsync(pipe.Reader, TimeSpan.FromMilliseconds(2));
        long largest_chunk = 0;
        await RenderAsync(pipe.Writer, () =>
        {
            largest_chunk = Math.Max(largest_chunk, pipe.Writer.UnflushedBytes);
            return PdfWriter.FlushAsync(pipe.Writer, CancellationToken.None);
        }, null);
        await pipe.Writer.CompleteAsync();
        var (got, most_waiting) = await read;
        Assert.Equal(want, got);
        // Each flush puts one page (or the end) in whole, and waits while more than the threshold
        // waits: so at most the largest chunk plus the threshold. Without the wait it would be the
        // whole document.
        var page_bound = largest_chunk + threshold;
        Assert.True(most_waiting <= page_bound, $"{most_waiting} bytes waited in the pipe, more than the largest chunk plus the threshold ({page_bound})");
        Assert.True(want.Length > page_bound * 3, $"the document ({want.Length} bytes) is too small to show backpressure");
    }

    [Fact]
    public async Task A_flush_cancelled_before_it_starts_loses_nothing()
    {
        var want = Reference();
        var kept = new MemoryStream();
        var output = PipeWriter.Create(kept, new StreamPipeWriterOptions(leaveOpen: true));
        var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        var first = true;
        await RenderAsync(output, async () =>
        {
            if (first)
            {
                first = false;
                await Assert.ThrowsAnyAsync<OperationCanceledException>(() => PdfWriter.FlushAsync(output, cancelled.Token).AsTask());
            }
            // The bytes stayed in the pipe, so this flush sends them.
            await PdfWriter.FlushAsync(output, CancellationToken.None);
        }, null);
        await output.CompleteAsync();
        Assert.Equal(want, kept.ToArray());
    }

    [Fact]
    public async Task A_pending_flush_cancelled_throws_and_leaves_no_memory_held()
    {
        var stream = new GatedStream();
        var output = PipeWriter.Create(stream, new StreamPipeWriterOptions(leaveOpen: true));
        var cts = new CancellationTokenSource();
        var render = RenderAsync(output, () => PdfWriter.FlushAsync(output, cts.Token), null);
        await Until(stream.NextFlush(), render);
        cts.Cancel();
        // RenderAsync's `using` disposes the writer on the way out, and Dispose throws if zpdf
        // still held a buffer, so a clean OperationCanceledException means nothing was held.
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => render);
    }

    [Fact]
    public async Task FlushAsync_turns_a_cancelled_flush_and_a_stopped_reader_into_exceptions()
    {
        var pipe = new Pipe(new PipeOptions(pauseWriterThreshold: 1, resumeWriterThreshold: 1));
        pipe.Writer.Write("x"u8);
        var pending = PdfWriter.FlushAsync(pipe.Writer, CancellationToken.None).AsTask();
        pipe.Writer.CancelPendingFlush();
        await Assert.ThrowsAsync<OperationCanceledException>(() => pending);

        var stopped = new Pipe();
        await stopped.Reader.CompleteAsync();
        stopped.Writer.Write("x"u8);
        Assert.Equal(
            "the PipeReader stopped reading before the PDF was written",
            (await Assert.ThrowsAsync<IOException>(() => PdfWriter.FlushAsync(stopped.Writer, CancellationToken.None).AsTask())).Message);
    }

    [Fact]
    public void An_exception_from_the_output_comes_back_as_itself_from_the_call_that_wrote()
    {
        var header_fails = new FailingBufferWriter(failAfter: 0);
        var at_create = Assert.Throws<IOException>(() => PdfWriter.Create(header_fails, compress: true));
        Assert.Equal(FailingBufferWriter.Message, at_create.Message);

        // The header fits; the first page's bytes do not.
        var page_fails = new FailingBufferWriter(failAfter: 1);
        using var writer = PdfWriter.Create(page_fails, compress: true);
        var font = writer.AddStandardFont(StandardFont.Helvetica);
        var page = DrawPage(writer, font, 0);
        Assert.Equal(FailingBufferWriter.Message, Assert.Throws<IOException>(() => writer.EndPage(page)).Message);
        Assert.False(writer.Lent);
        // The document cannot be written further, and says so in zpdf's words.
        Assert.Equal("DocumentFailed", Assert.Throws<ZpdfException>(writer.Finish).ErrorName);
    }

    [Fact]
    public void Text_drawn_later_reaches_the_output_when_DrawTextLater_returns()
    {
        var output = new ArrayBufferWriter<byte>();
        using (var writer = PdfWriter.Create(output, compress: false))
        {
            var font = writer.AddStandardFont(StandardFont.Helvetica);
            var page = writer.BeginPage(612, 792);
            var later = writer.ReserveLater(page);
            writer.EndPage(page);
            var before = output.WrittenCount;
            writer.DrawTextLater(later, font, 9, 270, 30, PdfColor.Black, "Page 1 of 1", TextDirection.FromText);
            Assert.True(output.WrittenCount > before, "DrawTextLater wrote nothing into the output before it returned");
            Assert.False(writer.Lent);
            writer.Finish();
        }

        using var reader = PdfReader.Open(output.WrittenSpan);
        Assert.Equal(["Page 1 of 1"], reader.ReadText(0).Runs.Select(r => r.Text));
    }

    [Fact]
    public void An_embedded_font_shapes_its_text_and_reads_back()
    {
        var output = new ArrayBufferWriter<byte>();
        using (var writer = PdfWriter.Create(output, compress: true))
        {
            var font = writer.AddFont(TestFont());
            var page = writer.BeginPage(400, 300);
            writer.DrawText(page, font, 14, 20, 250, new PdfColor(0.2, 0.2, 0.6), "office café Ω", TextDirection.FromText);
            writer.DrawLine(page, 20, 240, 380, 240, 0.5, PdfColor.Black);
            writer.FillRect(page, 20, 20, 50, 50, new PdfColor(0.9, 0.9, 0.9));
            writer.StrokeRect(page, 80, 20, 50, 50, 1, PdfColor.Black);
            writer.EndPage(page);
            writer.Finish();
        }

        using var reader = PdfReader.Open(output.WrittenSpan);
        Assert.Equal(new PdfBox(0, 0, 400, 300), reader.GetPage(0).MediaBox);
        var run = Assert.Single(reader.ReadText(0).Runs);
        Assert.Equal(("office café Ω", 20.0, 250.0, 14.0), (run.Text, run.X, run.Y, run.Size));
        Assert.EndsWith("+Roboto-Regular", run.Font);
    }

    private static byte[] Fixture(string name) =>
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", name));

    [Fact]
    public void An_image_is_written_when_AddImage_returns_and_is_in_the_PDF_once_for_two_pages()
    {
        var output = new ArrayBufferWriter<byte>();
        using (var writer = PdfWriter.Create(output, compress: false))
        {
            var before = output.WrittenCount;
            // Stored 16 x 32 with Exif orientation 6 (turned a quarter clockwise to be shown).
            var image = writer.AddImage(Fixture("orient-6.png"));
            Assert.True(output.WrittenCount > before, "AddImage wrote nothing into the output before it returned");
            Assert.False(writer.Lent);
            Assert.Equal((32u, 16u), (image.Width, image.Height));
            for (var p = 0; p < 2; p++)
            {
                var page = writer.BeginPage(200, 100);
                writer.DrawImage(page, image, 10, 10, image.Width * 4, image.Height * 4);
                writer.EndPage(page);
            }
            writer.Finish();
        }

        var pdf = System.Text.Encoding.Latin1.GetString(output.WrittenSpan);
        Assert.Equal(1, CountOf(pdf, "/Subtype /Image"));
        Assert.Equal(2, CountOf(pdf, " cm\n/X"));
        using var reader = PdfReader.Open(output.WrittenSpan);
        Assert.Equal(2, reader.PageCount);
        Assert.Empty(reader.ReadText(1).Runs);
    }

    [Fact]
    public void A_refused_image_throws_its_error_and_the_document_goes_on()
    {
        var output = new ArrayBufferWriter<byte>();
        using (var writer = PdfWriter.Create(output, compress: true))
        {
            var before = output.WrittenCount;
            Assert.Equal("UnsupportedImage", Assert.Throws<ZpdfException>(() => writer.AddImage("GIF89a"u8)).ErrorName);
            var truncated = Fixture("gray.jpg").AsSpan(0, 100).ToArray();
            Assert.Equal("InvalidImage", Assert.Throws<ZpdfException>(() => writer.AddImage(truncated)).ErrorName);
            Assert.Equal(before, output.WrittenCount);
            var image = writer.AddImage(Fixture("gray.jpg"));
            var page = writer.BeginPage(100, 100);
            Assert.Equal("InvalidNumber", Assert.Throws<ZpdfException>(() => writer.DrawImage(page, image, 0, 0, 0, 10)).ErrorName);
            writer.DrawImage(page, image, 0, 0, 32, 16);
            writer.EndPage(page);
            writer.Finish();
        }

        using var reader = PdfReader.Open(output.WrittenSpan);
        Assert.Equal(1, reader.PageCount);
    }

    private static int CountOf(string text, string part)
    {
        var count = 0;
        for (var at = text.IndexOf(part, StringComparison.Ordinal); at >= 0; at = text.IndexOf(part, at + 1, StringComparison.Ordinal))
        {
            count++;
        }
        return count;
    }

    // The PDF names of the 14 standard fonts' text faces (ISO 32000-1, 9.6.2.2), in StandardFont's
    // order: if zpdf's numbering and this enum ever disagree, a name read back differs.
    [Theory]
    [InlineData(StandardFont.Helvetica, "Helvetica")]
    [InlineData(StandardFont.HelveticaBold, "Helvetica-Bold")]
    [InlineData(StandardFont.HelveticaOblique, "Helvetica-Oblique")]
    [InlineData(StandardFont.HelveticaBoldOblique, "Helvetica-BoldOblique")]
    [InlineData(StandardFont.TimesRoman, "Times-Roman")]
    [InlineData(StandardFont.TimesBold, "Times-Bold")]
    [InlineData(StandardFont.TimesItalic, "Times-Italic")]
    [InlineData(StandardFont.TimesBoldItalic, "Times-BoldItalic")]
    [InlineData(StandardFont.Courier, "Courier")]
    [InlineData(StandardFont.CourierBold, "Courier-Bold")]
    [InlineData(StandardFont.CourierOblique, "Courier-Oblique")]
    [InlineData(StandardFont.CourierBoldOblique, "Courier-BoldOblique")]
    public void Each_standard_font_is_the_one_its_name_says(StandardFont font, string baseFont)
    {
        var output = new ArrayBufferWriter<byte>();
        using (var writer = PdfWriter.Create(output, compress: true))
        {
            var id = writer.AddStandardFont(font);
            var page = writer.BeginPage(200, 200);
            writer.DrawText(page, id, 12, 10, 100, PdfColor.Black, "Abc", TextDirection.FromText);
            writer.EndPage(page);
            writer.Finish();
        }

        using var reader = PdfReader.Open(output.WrittenSpan);
        var run = Assert.Single(reader.ReadText(0).Runs);
        Assert.Equal(("Abc", baseFont), (run.Text, run.Font));
    }

    [Fact]
    public void Text_that_is_not_valid_UTF_16_throws_instead_of_drawing_a_replacement()
    {
        using var writer = PdfWriter.Create(new ArrayBufferWriter<byte>(), compress: true);
        var font = writer.AddStandardFont(StandardFont.Helvetica);
        var page = writer.BeginPage(200, 200);
        Assert.ThrowsAny<ArgumentException>(() => writer.DrawText(page, font, 12, 10, 100, PdfColor.Black, "a\uD800b", TextDirection.FromText));
    }

    [Fact]
    public void A_direction_zpdf_does_not_know_is_refused_by_name()
    {
        using var writer = PdfWriter.Create(new ArrayBufferWriter<byte>(), compress: true);
        var font = writer.AddStandardFont(StandardFont.Helvetica);
        var page = writer.BeginPage(200, 200);
        var later = writer.ReserveLater(page);
        Assert.Equal("InvalidDirection", Assert.Throws<ZpdfException>(() => writer.DrawText(page, font, 12, 10, 100, PdfColor.Black, "a", (TextDirection)9)).ErrorName);
        Assert.Equal("InvalidDirection", Assert.Throws<ZpdfException>(() => writer.DrawTextLater(later, font, 12, 10, 100, PdfColor.Black, "a", (TextDirection)9)).ErrorName);
    }

    [Fact]
    public void Long_text_goes_through_the_pooled_buffer_and_reads_back_whole()
    {
        var line = string.Concat(Enumerable.Repeat("long line ", 200));
        var output = new ArrayBufferWriter<byte>();
        using (var writer = PdfWriter.Create(output, compress: true))
        {
            var font = writer.AddStandardFont(StandardFont.Courier);
            var page = writer.BeginPage(20000, 100);
            writer.DrawText(page, font, 8, 0, 50, PdfColor.Black, line, TextDirection.FromText);
            writer.EndPage(page);
            writer.Finish();
        }

        using var reader = PdfReader.Open(output.WrittenSpan);
        Assert.Equal(line.Replace(" ", ""), string.Concat(reader.ReadText(0).Runs.Select(r => r.Text)).Replace(" ", ""));
    }

    [Fact]
    public void A_disposed_writer_throws_and_disposing_twice_is_allowed()
    {
        var writer = PdfWriter.Create(new ArrayBufferWriter<byte>(), compress: true);
        writer.Dispose();
        writer.Dispose();
        Assert.Throws<ObjectDisposedException>(() => writer.BeginPage(10, 10));
    }

    // Waits for `step`, unless the render ends first: then its failure is the test's, not a wait
    // that never ends.
    private static async Task Until(Task step, Task render)
    {
        if (await Task.WhenAny(step, render) == render)
        {
            await render;
            throw new InvalidOperationException("the render ended before the step the test waited for");
        }
    }

    // Reads a pipe to its end, pausing `delay` between reads; the bytes and the most that waited
    // unread at once.
    private static async Task<(byte[], long)> ReadAllAsync(PipeReader reader, TimeSpan delay)
    {
        var all = new MemoryStream();
        long most = 0;
        while (true)
        {
            if (delay > TimeSpan.Zero)
            {
                await Task.Delay(delay);
            }
            var result = await reader.ReadAsync();
            most = Math.Max(most, result.Buffer.Length);
            foreach (var segment in result.Buffer)
            {
                all.Write(segment.Span);
            }
            reader.AdvanceTo(result.Buffer.End);
            if (result.IsCompleted)
            {
                break;
            }
        }
        await reader.CompleteAsync();
        return (all.ToArray(), most);
    }

    // An IBufferWriter over one array it never grows; counts what is lent and advanced.
    private sealed class CountingBufferWriter : IBufferWriter<byte>
    {
        private readonly byte[] _array;
        private int _written;

        public CountingBufferWriter(int capacity) => _array = new byte[capacity];

        public long Advanced { get; private set; }
        public int GetMemoryCalls { get; private set; }
        public ReadOnlySpan<byte> Written => _array.AsSpan(0, _written);

        public Memory<byte> GetMemory(int sizeHint)
        {
            GetMemoryCalls++;
            if (_array.Length - _written < Math.Max(sizeHint, 1))
            {
                throw new InvalidOperationException("the test's array is too small");
            }
            return _array.AsMemory(_written);
        }

        public Span<byte> GetSpan(int sizeHint) => GetMemory(sizeHint).Span;

        public void Advance(int count)
        {
            _written += count;
            Advanced += count;
        }
    }

    // Lends memory `failAfter` times, then throws.
    private sealed class FailingBufferWriter : IBufferWriter<byte>
    {
        public const string Message = "disk full (test)";
        private readonly int _failAfter;
        private readonly byte[] _array = new byte[64 * 1024];
        private int _lends;

        public FailingBufferWriter(int failAfter) => _failAfter = failAfter;

        public Memory<byte> GetMemory(int sizeHint)
        {
            if (_lends++ >= _failAfter)
            {
                throw new IOException(Message);
            }
            return _array;
        }

        public Span<byte> GetSpan(int sizeHint) => GetMemory(sizeHint).Span;

        public void Advance(int count)
        {
        }
    }

    // A stream whose flushes complete when the test says (a PipeWriter over it flushes it once per
    // FlushAsync): each FlushAsync waits for Release, or for its token.
    private sealed class GatedStream : MemoryStream
    {
        private readonly object _lock = new();
        private TaskCompletionSource _started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private TaskCompletionSource _gate = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public override async Task FlushAsync(CancellationToken cancellationToken)
        {
            Task gate;
            lock (_lock)
            {
                gate = _gate.Task;
                _started.TrySetResult();
            }
            await gate.WaitAsync(cancellationToken);
        }

        // Waits until a flush has started and waits at the gate.
        public async Task NextFlush()
        {
            Task started;
            lock (_lock)
            {
                started = _started.Task;
            }
            await started;
        }

        public void Release()
        {
            lock (_lock)
            {
                _started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var gate = _gate;
                _gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                gate.SetResult();
            }
        }
    }
}
