using System;
using System.Buffers;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.IO;
using System.IO.Pipelines;
using System.Threading;
using System.Threading.Tasks;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using Zpdf.Native;

namespace Zpdf.AbiTest;

// Calls libzpdf through the generated declarations, as a .NET library would:
//
//     AbiTest <path to libzpdf> <a PDF with two or more pages>
//
// Writes a PDF, reads it back, reads the given PDF, and checks each struct's size against the
// size zpdf declared. Prints "abi-dotnet-test: ok" when every check passed.
internal static unsafe partial class Program
{
    private static int Main(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.WriteLine("usage: AbiTest <path to libzpdf> <a PDF with two or more pages>");
            return 2;
        }
        var library = args[0];
        NativeLibrary.SetDllImportResolver(typeof(ZpdfAbi).Assembly, (name, _, _) =>
            name == ZpdfAbi.LibraryName ? NativeLibrary.Load(library) : IntPtr.Zero);

        // A failure prints "(fail) <test>", which tools/mutate.py reads to name a C# mutant's kill.
        var failed = 0;
        failed += Run("round trip: write, read back, struct sizes", () => RoundTrip(args[1]));
        failed += Run("sync sink: a Stream sink gets the buffered bytes, and a throwing stream's exception", () => WithContext(ctx => CheckStreamSink((ZpdfContext*)ctx)));
        failed += Run("caller buffers: zpdf writes into the writer's memory, with no managed allocation or copy", () => WithContext(ZeroCopy));
        failed += Run("async: a Stream and a Pipe get the buffered document's bytes", () => WithContext(ctx => AsyncSameBytes(ctx).GetAwaiter().GetResult()));
        failed += Run("async: a page's flush is awaited, not blocked on, and the next page waits for it", () => WithContext(ctx => AsyncDoesNotBlock(ctx).GetAwaiter().GetResult()));
        failed += Run("async: a slow PipeReader holds the writer to one page plus the pipe's threshold", () => WithContext(ctx => AsyncSlowConsumer(ctx).GetAwaiter().GetResult()));
        failed += Run("async: cancellation, pending or before the flush, loses nothing and leaves no buffer", () => WithContext(ctx => AsyncCancellation(ctx).GetAwaiter().GetResult()));
        if (failed != 0)
        {
            return 1;
        }
        Console.WriteLine("abi-dotnet-test: ok");
        return 0;
    }

    private static int Run(string name, Action test)
    {
        try
        {
            test();
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"(fail) {name}: {e.GetType().Name}: {e.Message}");
            return 1;
        }
    }

    // A context for one test, which must end with nothing live and free cleanly: a buffer left
    // out (BuffersOutstanding) or a leak fails the test.
    private static void WithContext(Action<nint> test)
    {
        var ctx = ZpdfAbi.zpdf_context_new();
        Expect(ctx != null, "context");
        test((nint)ctx);
        nuint live;
        Check(ZpdfAbi.zpdf_live_bytes(ctx, &live));
        Expect(live == 0, $"{live} live bytes at the end");
        Check(ZpdfAbi.zpdf_context_free(ctx));
    }

    private static void RoundTrip(string otherPdf)
    {
        Expect(ZpdfAbi.zpdf_abi_version() == ZpdfAbi.AbiVersion, "abi version");
        Expect(Marshal.PtrToStringUTF8((IntPtr)ZpdfAbi.zpdf_error_name((int)ZpdfError.InvalidFont)) == "InvalidFont", "error name");
        CheckStructSizes();

        var ctx = ZpdfAbi.zpdf_context_new();
        Expect(ctx != null, "context");

        uint doc, font, page;
        Check(ZpdfAbi.zpdf_doc_new(ctx, 1, &doc));
        Check(ZpdfAbi.zpdf_doc_add_standard_font(ctx, doc, 0, &font));
        Check(ZpdfAbi.zpdf_doc_begin_page(ctx, doc, 612, 792, &page));
        var line = Encoding.UTF8.GetBytes("Hello from .NET");
        fixed (byte* text = line)
        {
            Check(ZpdfAbi.zpdf_doc_draw_text(ctx, doc, page, font, 12, 72, 720, 0, 0, 0, text, (nuint)line.Length, 0));
        }
        Check(ZpdfAbi.zpdf_doc_end_page(ctx, doc, page));
        byte* pdf;
        nuint pdf_len;
        Check(ZpdfAbi.zpdf_doc_finish(ctx, doc, &pdf, &pdf_len));
        Expect(ZpdfAbi.zpdf_context_free(ctx) == (int)ZpdfError.BuffersOutstanding, "context_free refuses while a buffer is out");

        uint reader, pages;
        Check(ZpdfAbi.zpdf_reader_open(ctx, pdf, pdf_len, &reader));
        Check(ZpdfAbi.zpdf_free(ctx, pdf, pdf_len));
        Check(ZpdfAbi.zpdf_reader_page_count(ctx, reader, &pages));
        Expect(pages == 1, "one page");
        PageInfo info;
        Check(ZpdfAbi.zpdf_reader_page(ctx, reader, 0, &info));
        Expect(info.media_box[2] == 612 && info.media_box[3] == 792, "media box");
        var read = PageText(ctx, reader, 0);
        Expect(read == "Hello from .NET", $"read back \"{read}\"");
        Check(ZpdfAbi.zpdf_reader_close(ctx, reader));
        Check(ZpdfAbi.zpdf_doc_close(ctx, doc));

        var other = File.ReadAllBytes(otherPdf);
        fixed (byte* bytes = other)
        {
            Check(ZpdfAbi.zpdf_reader_open(ctx, bytes, (nuint)other.Length, &reader));
        }
        Check(ZpdfAbi.zpdf_reader_page_count(ctx, reader, &pages));
        Expect(pages >= 2, "two or more pages");
        for (uint i = 0; i < pages; i++)
        {
            Expect(PageText(ctx, reader, i).Length > 0, $"text on page {i}");
        }
        Check(ZpdfAbi.zpdf_reader_close(ctx, reader));

        nuint live;
        Check(ZpdfAbi.zpdf_live_bytes(ctx, &live));
        Expect(live == 0, $"{live} live bytes at the end");
        Check(ZpdfAbi.zpdf_context_free(ctx));
    }

    // The page's runs, joined.
    private static string PageText(ZpdfContext* ctx, uint reader, uint index)
    {
        byte* buffer;
        nuint length;
        Check(ZpdfAbi.zpdf_reader_page_text(ctx, reader, index, &buffer, &length));
        var wire = new ReadOnlySpan<byte>(buffer, checked((int)length));
        var header = MemoryMarshal.Read<TextHeader>(wire);
        var runs_at = sizeof(TextHeader);
        var strings_at = runs_at + (int)header.run_count * sizeof(RunRecord) + (int)header.glyph_count * sizeof(GlyphRecord);
        Expect(strings_at + (int)header.strings_len == wire.Length, "page text length");
        var text = new StringBuilder();
        for (var i = 0; i < header.run_count; i++)
        {
            var run = MemoryMarshal.Read<RunRecord>(wire.Slice(runs_at + i * sizeof(RunRecord)));
            text.Append(Encoding.UTF8.GetString(wire.Slice(strings_at + (int)run.text_offset, (int)run.text_len)));
        }
        Check(ZpdfAbi.zpdf_free(ctx, buffer, length));
        return text.ToString();
    }

    // A field the generator mapped to a wider C# type would make the struct larger than the
    // Size zpdf gave it; StructLayout's Size cannot shrink a struct, so this sees it.
    private static void CheckStructSizes()
    {
        var count = 0;
        foreach (var type in typeof(ZpdfAbi).Assembly.GetTypes())
        {
            var layout = type.StructLayoutAttribute;
            // Size 0: a record of pointers, laid out as the platform's C struct (no fixed size).
            if (type.Namespace != "Zpdf.Native" || !type.IsValueType || type.IsEnum || type == typeof(ZpdfContext) || layout == null || layout.Size == 0)
            {
                continue;
            }
            var size = Marshal.SizeOf(type);
            Expect(size == layout.Size, $"{type.Name}: {size} bytes, zpdf says {layout.Size}");
            count++;
        }
        Expect(count >= 8, $"{count} wire records checked");
    }

    // A Stream sink gets the bytes a buffered document gives, and a stream that throws gives
    // its own exception back.
    private static void CheckStreamSink(ZpdfContext* ctx)
    {
        var buffered = WriteOnePage(ctx, null);
        using var stream = new MemoryStream();
        using (var sink = new ZpdfStreamSink(stream))
        {
            Expect(WriteOnePage(ctx, sink).Length == 0, "a sink document's finish gives no bytes");
        }
        Expect(stream.ToArray().AsSpan().SequenceEqual(buffered), $"sink wrote {stream.Length} bytes, the buffer {buffered.Length}");

        using var failing = new ZpdfStreamSink(new FailingStream());
        try
        {
            WriteOnePage(ctx, failing);
            Expect(false, "a failing stream's exception was not thrown");
        }
        catch (IOException e) when (e.Message == FailingStream.Message)
        {
        }
    }

    // One page in Helvetica, into the sink when there is one; the PDF the document gives back.
    private static byte[] WriteOnePage(ZpdfContext* ctx, ZpdfStreamSink? sink)
    {
        uint doc, font, page;
        if (sink == null)
        {
            Check(ZpdfAbi.zpdf_doc_new(ctx, 1, &doc));
        }
        else
        {
            var native = sink.Native;
            // The header is written now, so this can fail with the stream's exception too.
            var created = ZpdfAbi.zpdf_doc_new_sink(ctx, 1, &native, &doc);
            sink.ThrowIfFailed(created);
            Check(created);
        }
        try
        {
            Check(ZpdfAbi.zpdf_doc_add_standard_font(ctx, doc, 0, &font));
            Check(ZpdfAbi.zpdf_doc_begin_page(ctx, doc, 612, 792, &page));
            var line = Encoding.UTF8.GetBytes("Hello from a .NET Stream");
            fixed (byte* text = line)
            {
                Check(ZpdfAbi.zpdf_doc_draw_text(ctx, doc, page, font, 12, 72, 720, 0, 0, 0, text, (nuint)line.Length, 0));
            }
            var rc = ZpdfAbi.zpdf_doc_end_page(ctx, doc, page);
            sink?.ThrowIfFailed(rc);
            Check(rc);
            byte* pdf;
            nuint pdf_len;
            rc = ZpdfAbi.zpdf_doc_finish(ctx, doc, &pdf, &pdf_len);
            sink?.ThrowIfFailed(rc);
            Check(rc);
            var bytes = new ReadOnlySpan<byte>(pdf, checked((int)pdf_len)).ToArray();
            Check(ZpdfAbi.zpdf_free(ctx, pdf, pdf_len));
            return bytes;
        }
        finally
        {
            Check(ZpdfAbi.zpdf_doc_close(ctx, doc));
        }
    }

    private sealed class FailingStream : MemoryStream
    {
        public const string Message = "disk full (test)";

        public override void Write(ReadOnlySpan<byte> buffer)
        {
            throw new IOException(Message);
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            throw new IOException(Message);
        }
    }

    // ---- caller-buffer sink and async ----

    private const int AsyncPages = 20;

    private static uint NewDocument(nint ctx)
    {
        uint doc;
        Check(ZpdfAbi.zpdf_doc_new((ZpdfContext*)ctx, 1, &doc));
        return doc;
    }

    private static uint NewSinkDocument(nint ctx, ZpdfBufferSink sink)
    {
        uint doc;
        var native = sink.Native;
        var rc = ZpdfAbi.zpdf_doc_new_sink((ZpdfContext*)ctx, 1, &native, &doc);
        sink.ThrowIfFailed(rc);
        Check(rc);
        return doc;
    }

    // The test document's lines, made once, so drawing allocates nothing in the zero-copy test.
    private static readonly byte[][] Lines = MakeLines();

    private static byte[][] MakeLines()
    {
        var lines = new byte[AsyncPages * 40][];
        for (var i = 0; i < lines.Length; i++)
        {
            lines[i] = Encoding.UTF8.GetBytes($"page {i / 40} line {i % 40} async office");
        }
        return lines;
    }

    // Draws page `index` (40 lines of Helvetica), up to but not including end_page.
    private static uint DrawPage(nint ctx, uint doc, int index)
    {
        var c = (ZpdfContext*)ctx;
        uint font, page;
        Check(ZpdfAbi.zpdf_doc_add_standard_font(c, doc, 0, &font));
        Check(ZpdfAbi.zpdf_doc_begin_page(c, doc, 612, 792, &page));
        for (var l = 0; l < 40; l++)
        {
            var line = Lines[index * 40 + l];
            fixed (byte* text = line)
            {
                Check(ZpdfAbi.zpdf_doc_draw_text(c, doc, page, font, 10, 36, 760 - l * 14, 0, 0, 0, text, (nuint)line.Length, 0));
            }
        }
        return page;
    }

    private static void EndPage(nint ctx, uint doc, uint page, ZpdfBufferSink? sink)
    {
        var rc = ZpdfAbi.zpdf_doc_end_page((ZpdfContext*)ctx, doc, page);
        sink?.ThrowIfFailed(rc);
        Check(rc);
        Expect(sink == null || !sink.Lent, "zpdf held the writer's memory after end_page returned");
    }

    // finish; for a sink document the rest went to the sink and nothing comes back.
    private static byte[] Finish(nint ctx, uint doc, ZpdfBufferSink? sink)
    {
        byte* pdf;
        nuint len;
        var rc = ZpdfAbi.zpdf_doc_finish((ZpdfContext*)ctx, doc, &pdf, &len);
        sink?.ThrowIfFailed(rc);
        Check(rc);
        Expect(sink == null || !sink.Lent, "zpdf held the writer's memory after finish returned");
        var bytes = new ReadOnlySpan<byte>(pdf, checked((int)len)).ToArray();
        Check(ZpdfAbi.zpdf_free((ZpdfContext*)ctx, pdf, len));
        return bytes;
    }

    private static void CloseDocument(nint ctx, uint doc) => Check(ZpdfAbi.zpdf_doc_close((ZpdfContext*)ctx, doc));

    // The document written all at once, for comparison.
    private static byte[] BufferedBytes(nint ctx)
    {
        var doc = NewDocument(ctx);
        try
        {
            for (var p = 0; p < AsyncPages; p++)
            {
                EndPage(ctx, doc, DrawPage(ctx, doc, p), null);
            }
            return Finish(ctx, doc, null);
        }
        finally
        {
            CloseDocument(ctx, doc);
        }
    }

    private static void ZeroCopy(nint ctx)
    {
        var want = BufferedBytes(ctx);

        // The base rate, so the counter is shown to see allocations: the push sink into a
        // MemoryStream allocates as the stream grows.
        var pushed = new MemoryStream();
        long push_allocated;
        using (var push = new ZpdfStreamSink(pushed))
        {
            uint doc;
            var native = push.Native;
            Check(ZpdfAbi.zpdf_doc_new_sink((ZpdfContext*)ctx, 1, &native, &doc));
            push_allocated = MeasureWrites(ctx, doc, null);
            CloseDocument(ctx, doc);
        }
        Expect(pushed.ToArray().AsSpan().SequenceEqual(want), "push sink bytes");
        Expect(push_allocated > 0, "the allocation counter saw nothing on the push path (it must, for the test to mean anything)");

        // The caller-buffer sink into a writer over one preallocated array: zpdf's writes land in
        // that array through GetMemory and Advance, and the calls that write allocate nothing.
        var target = new CountingBufferWriter(want.Length + 64 * 1024);
        long allocated;
        using (var sink = new ZpdfBufferSink(target))
        {
            var doc = NewSinkDocument(ctx, sink);
            allocated = MeasureWrites(ctx, doc, sink);
            CloseDocument(ctx, doc);
        }
        Expect(target.Written.SequenceEqual(want), $"caller buffers: {target.Written.Length} bytes, buffered {want.Length}");
        Expect(target.Advanced == want.Length, $"{target.Advanced} bytes advanced for a {want.Length}-byte PDF: every byte arrives once, by Advance");
        Expect(target.GetMemoryCalls > 0 && target.GetMemoryCalls <= AsyncPages * 4 + 4, $"{target.GetMemoryCalls} buffers lent");
        Expect(allocated == 0, $"{allocated} managed bytes allocated by the calls that wrote into caller buffers");
    }

    // Draws every page and finishes; the managed bytes allocated during end_page and finish,
    // the calls in which zpdf writes into the sink.
    private static long MeasureWrites(nint ctx, uint doc, ZpdfBufferSink? sink)
    {
        long allocated = 0;
        for (var p = 0; p < AsyncPages; p++)
        {
            var page = DrawPage(ctx, doc, p);
            var before = GC.GetAllocatedBytesForCurrentThread();
            var rc = ZpdfAbi.zpdf_doc_end_page((ZpdfContext*)ctx, doc, page);
            allocated += GC.GetAllocatedBytesForCurrentThread() - before;
            sink?.ThrowIfFailed(rc);
            Check(rc);
        }
        byte* pdf;
        nuint len;
        var start = GC.GetAllocatedBytesForCurrentThread();
        var finished = ZpdfAbi.zpdf_doc_finish((ZpdfContext*)ctx, doc, &pdf, &len);
        allocated += GC.GetAllocatedBytesForCurrentThread() - start;
        Check(finished);
        Expect(len == 0, "a sink document's finish gave bytes back");
        return allocated;
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

        public Memory<byte> GetMemory(int sizeHint = 0)
        {
            GetMemoryCalls++;
            Expect(_array.Length - _written >= Math.Max(sizeHint, 1), "the test's array is too small");
            return _array.AsMemory(_written);
        }

        public Span<byte> GetSpan(int sizeHint = 0) => GetMemory(sizeHint).Span;

        public void Advance(int count)
        {
            _written += count;
            Advanced += count;
        }
    }

    private static void Check(int rc)
    {
        if (rc != 0)
        {
            var name = Marshal.PtrToStringUTF8((IntPtr)ZpdfAbi.zpdf_error_name(rc));
            throw new InvalidOperationException($"zpdf call failed: {rc} {name}");
        }
    }

    private static void Expect(bool condition, string what)
    {
        if (!condition)
        {
            throw new InvalidOperationException($"abi-dotnet-test: failed: {what}");
        }
    }
}
