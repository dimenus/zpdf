using System;
using System.Buffers;
using System.IO;
using System.IO.Pipelines;
using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Zpdf.Native;

namespace Zpdf;

/// <summary>
/// Writes a PDF into an <see cref="IBufferWriter{T}"/>, page by page, with no managed copy.
/// </summary>
/// <remarks>
/// <para>
/// zpdf asks the writer for memory (<c>GetMemory</c>, pinned for the call), writes the PDF's bytes
/// straight into it, and gives it back with <c>Advance</c>. The calls that write are
/// <see cref="Create"/> (the header), <see cref="AddImage"/>, <see cref="EndPage"/>,
/// <see cref="DrawTextLater"/> and <see cref="Finish"/>; each has passed on everything it wrote when
/// it returns, and none of them allocates managed memory for the PDF.
/// </para>
/// <para>
/// Async: when any call returns, zpdf holds none of the writer's memory, so a <see cref="PipeWriter"/>
/// may be flushed between calls (a Stream: <c>PipeWriter.Create(stream)</c>). Await
/// <see cref="FlushAsync"/> after each <see cref="EndPage"/> and after <see cref="Finish"/>: that is
/// where the I/O waits, where a slow reader holds the writer back (the pipe's pause threshold), and
/// where a <see cref="CancellationToken"/> applies. Each page is CPU work done in the call, with no
/// I/O. A cancelled or failed flush leaves the PDF part-written; dispose the writer, and what to do
/// with the partial PDF is the destination's owner's call.
/// </para>
/// <para>
/// An exception the buffer writer throws comes back from the call that wrote, as itself, and the
/// document cannot be written further. One thread at a time, as <see cref="PdfReader"/>; units are
/// points in PDF space, y up from the bottom of the page.
/// </para>
/// </remarks>
public sealed unsafe partial class PdfWriter : IDisposable
{
    // Text up to this many UTF-8 bytes is encoded on the stack; longer text in a pooled array.
    internal const int StackTextBytes = 512;

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    private readonly ContextHandle _context;
    private readonly IBufferWriter<byte> _output;
    private GCHandle _self;
    private MemoryHandle _pinned;
    private bool _lent;
    private Exception? _failure;
    private uint _document;

    private PdfWriter(ContextHandle context, IBufferWriter<byte> output)
    {
        _context = context;
        _output = output;
        _self = GCHandle.Alloc(this);
    }

    /// <summary>Starts a PDF in <paramref name="output"/> and writes its header.</summary>
    /// <param name="compress">Flate-compress the content streams and fonts.</param>
    public static PdfWriter Create(IBufferWriter<byte> output, bool compress)
    {
        ArgumentNullException.ThrowIfNull(output);
        var writer = new PdfWriter(ContextHandle.Create(), output);
        try
        {
            var sink = new Sink
            {
                user = (void*)GCHandle.ToIntPtr(writer._self),
                get_buffer = &GetBuffer,
                commit = &Commit,
            };
            uint document;
            writer.Call(ZpdfAbi.zpdf_doc_new_sink(writer._context.Pointer, compress ? 1u : 0u, &sink, &document));
            writer._document = document;
            return writer;
        }
        catch
        {
            writer.Dispose();
            throw;
        }
    }

    /// <summary>Embeds a TrueType or OpenType font (its first face, default instance). zpdf copies
    /// the bytes.</summary>
    public FontId AddFont(ReadOnlySpan<byte> fontFile)
    {
        var context = Enter();
        uint font;
        uint id;
        fixed (byte* bytes = fontFile)
        {
            Call(ZpdfAbi.zpdf_font_open(context, bytes, (nuint)fontFile.Length, 0, null, 0, &font));
        }
        Call(ZpdfAbi.zpdf_doc_add_font(context, _document, font, &id));
        return new FontId(id);
    }

    /// <summary>One of the 14 standard fonts that need no embedding (the text ones).</summary>
    public FontId AddStandardFont(StandardFont font)
    {
        var context = Enter();
        uint standard;
        uint id;
        Call(ZpdfAbi.zpdf_font_open_standard(context, (uint)font, &standard));
        Call(ZpdfAbi.zpdf_doc_add_font(context, _document, standard, &id));
        Call(ZpdfAbi.zpdf_font_close(context, standard));
        return new FontId(id);
    }

    /// <summary>Starts a page; one page is open at a time.</summary>
    public PageId BeginPage(double width, double height)
    {
        uint page;
        Call(ZpdfAbi.zpdf_doc_begin_page(Enter(), _document, width, height, &page));
        return new PageId(page);
    }

    /// <summary>One line of text with its first glyph's origin at (<paramref name="x"/>,
    /// <paramref name="y"/>), shaped with the font.</summary>
    public void DrawText(PageId page, FontId font, double size, double x, double y, PdfColor color, ReadOnlySpan<char> text, TextDirection direction)
    {
        var context = Enter();
        Span<byte> stack = stackalloc byte[StackTextBytes];
        var utf8 = Encode(text, stack, out var rented);
        try
        {
            fixed (byte* bytes = utf8)
            {
                Call(ZpdfAbi.zpdf_doc_draw_text(context, _document, page.Value, font.Value, size, x, y, color.Red, color.Green, color.Blue, bytes, (nuint)utf8.Length, (uint)direction));
            }
        }
        finally
        {
            Return(rented);
        }
    }

    public void DrawLine(PageId page, double x1, double y1, double x2, double y2, double width, PdfColor color) =>
        Call(ZpdfAbi.zpdf_doc_draw_line(Enter(), _document, page.Value, x1, y1, x2, y2, width, color.Red, color.Green, color.Blue));

    /// <summary>(<paramref name="x"/>, <paramref name="y"/>) is the rectangle's bottom-left corner.</summary>
    public void FillRect(PageId page, double x, double y, double width, double height, PdfColor color) =>
        Call(ZpdfAbi.zpdf_doc_fill_rect(Enter(), _document, page.Value, x, y, width, height, color.Red, color.Green, color.Blue));

    /// <summary>(<paramref name="x"/>, <paramref name="y"/>) is the rectangle's bottom-left corner.</summary>
    public void StrokeRect(PageId page, double x, double y, double width, double height, double lineWidth, PdfColor color) =>
        Call(ZpdfAbi.zpdf_doc_stroke_rect(Enter(), _document, page.Value, x, y, width, height, lineWidth, color.Red, color.Green, color.Blue));

    /// <summary>Adds a JPEG or PNG image and writes it into the output now, as <see cref="EndPage"/>
    /// does, so the document keeps its size and not its pixels: an image drawn on many pages is in
    /// the PDF once, and one that is never drawn is in it too. zpdf reads the bytes only during the
    /// call. A file zpdf refuses (zpdf's src/image.zig lists what) throws
    /// <see cref="ZpdfException"/> InvalidImage, UnsupportedImage or TooLarge and adds nothing.</summary>
    public PdfImage AddImage(ReadOnlySpan<byte> image)
    {
        var context = Enter();
        uint id;
        uint width;
        uint height;
        fixed (byte* bytes = image)
        {
            Call(ZpdfAbi.zpdf_doc_add_image(context, _document, bytes, (nuint)image.Length, &id));
        }
        Call(ZpdfAbi.zpdf_doc_image_size(context, _document, id, &width, &height));
        return new PdfImage(id, width, height);
    }

    /// <summary>Draws <paramref name="image"/> stretched to fill the rectangle whose bottom-left
    /// corner is (<paramref name="x"/>, <paramref name="y"/>), turned as its Exif orientation says.
    /// Keep <see cref="PdfImage.Width"/> to <see cref="PdfImage.Height"/> to keep its shape.</summary>
    public void DrawImage(PageId page, PdfImage image, double x, double y, double width, double height) =>
        Call(ZpdfAbi.zpdf_doc_draw_image(Enter(), _document, page.Value, image.Value, x, y, width, height));

    /// <summary>A place on the page for text drawn later, such as "Page 3 of 12". Every place must
    /// be drawn before <see cref="Finish"/>.</summary>
    public LaterId ReserveLater(PageId page)
    {
        uint later;
        Call(ZpdfAbi.zpdf_doc_reserve_later(Enter(), _document, page.Value, &later));
        return new LaterId(later);
    }

    /// <summary>Draws a reserved place's text, once; its page may have ended. Writes into the
    /// output, as <see cref="EndPage"/> does.</summary>
    public void DrawTextLater(LaterId later, FontId font, double size, double x, double y, PdfColor color, ReadOnlySpan<char> text, TextDirection direction)
    {
        var context = Enter();
        Span<byte> stack = stackalloc byte[StackTextBytes];
        var utf8 = Encode(text, stack, out var rented);
        try
        {
            fixed (byte* bytes = utf8)
            {
                Call(ZpdfAbi.zpdf_doc_draw_text_later(context, _document, later.Value, font.Value, size, x, y, color.Red, color.Green, color.Blue, bytes, (nuint)utf8.Length, (uint)direction));
            }
        }
        finally
        {
            Return(rented);
        }
    }

    /// <summary>Writes the page into the output and frees its drawing.</summary>
    public void EndPage(PageId page) => Call(ZpdfAbi.zpdf_doc_end_page(Enter(), _document, page.Value));

    /// <summary>Writes the rest of the PDF (fonts, page tree, cross-reference table) into the
    /// output, once.</summary>
    public void Finish()
    {
        byte* rest;
        nuint length;
        Call(ZpdfAbi.zpdf_doc_finish(Enter(), _document, &rest, &length));
        if (length != 0)
        {
            throw new InvalidOperationException($"zpdf_doc_finish gave {length} bytes back for a sink document; they belong in the output.");
        }
    }

    /// <summary>Frees the document and its native memory. The output keeps what was written.</summary>
    public void Dispose()
    {
        try
        {
            if (_lent)
            {
                _pinned.Dispose();
                _lent = false;
            }
            _context.Free();
        }
        finally
        {
            if (_self.IsAllocated)
            {
                _self.Free();
            }
        }
    }

    // Whether zpdf holds the output's memory now: never between calls.
    internal bool Lent => _lent;

    internal nuint LiveBytes() => _context.LiveBytes();

    private ZpdfContext* Enter()
    {
        ObjectDisposedException.ThrowIf(_context.IsClosed, this);
        return _context.Pointer;
    }

    // A status from a zpdf call on this document: the output's own exception after SinkFailed,
    // else zpdf's.
    private void Call(int status)
    {
        if (status == (int)ZpdfError.SinkFailed && _failure != null)
        {
            var failure = _failure;
            _failure = null;
            ExceptionDispatchInfo.Throw(failure);
        }
        ZpdfLibrary.Check(status);
    }

    // UTF-8 for zpdf, in `stack` when it fits; invalid UTF-16 (a lone surrogate) throws rather than
    // being drawn as U+FFFD.
    internal static ReadOnlySpan<byte> Encode(ReadOnlySpan<char> text, Span<byte> stack, out byte[]? rented)
    {
        var most = StrictUtf8.GetMaxByteCount(text.Length);
        rented = most > stack.Length ? ArrayPool<byte>.Shared.Rent(most) : null;
        var buffer = rented ?? stack;
        return buffer[..StrictUtf8.GetBytes(text, buffer)];
    }

    internal static void Return(byte[]? rented)
    {
        if (rented != null)
        {
            ArrayPool<byte>.Shared.Return(rented);
        }
    }

    // The sink's callbacks. An exception never crosses into zpdf: it is kept, the callback returns
    // non-zero, and Call throws it when zpdf returns SinkFailed.
    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static int GetBuffer(void* user, nuint minLen, byte** buffer, nuint* len)
    {
        var writer = (PdfWriter)GCHandle.FromIntPtr((IntPtr)user).Target!;
        try
        {
            // zpdf asks for at most 64 KiB, and commits each buffer before it asks again.
            var memory = writer._output.GetMemory(checked((int)minLen));
            writer._pinned = memory.Pin();
            writer._lent = true;
            *buffer = (byte*)writer._pinned.Pointer;
            *len = (nuint)memory.Length;
            return 0;
        }
        catch (Exception e)
        {
            writer._failure = e;
            return -1;
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static int Commit(void* user, nuint len)
    {
        var writer = (PdfWriter)GCHandle.FromIntPtr((IntPtr)user).Target!;
        try
        {
            writer._pinned.Dispose();
            writer._lent = false;
            writer._output.Advance(checked((int)len));
            return 0;
        }
        catch (Exception e)
        {
            writer._failure = e;
            return -1;
        }
    }
}

/// <summary>A font added to one <see cref="PdfWriter"/>.</summary>
public readonly record struct FontId
{
    internal FontId(uint value) => Value = value;

    internal uint Value { get; }
}

/// <summary>A page of one <see cref="PdfWriter"/>.</summary>
public readonly record struct PageId
{
    internal PageId(uint value) => Value = value;

    internal uint Value { get; }
}

/// <summary>A place reserved with <see cref="PdfWriter.ReserveLater"/>.</summary>
public readonly record struct LaterId
{
    internal LaterId(uint value) => Value = value;

    internal uint Value { get; }
}

/// <summary>An image added to one <see cref="PdfWriter"/>, with its size in pixels as it is shown
/// (after its Exif orientation).</summary>
public readonly record struct PdfImage
{
    internal PdfImage(uint value, uint width, uint height)
    {
        Value = value;
        Width = width;
        Height = height;
    }

    internal uint Value { get; }

    public uint Width { get; }

    public uint Height { get; }
}

/// <summary>DeviceRGB, each component from 0 to 1.</summary>
public readonly record struct PdfColor(double Red, double Green, double Blue)
{
    public static PdfColor Black => new(0, 0, 0);
}

/// <summary>The standard text fonts, in zpdf's order (its C ABI takes the number).</summary>
public enum StandardFont
{
    Helvetica = 0,
    HelveticaBold = 1,
    HelveticaOblique = 2,
    HelveticaBoldOblique = 3,
    TimesRoman = 4,
    TimesBold = 5,
    TimesItalic = 6,
    TimesBoldItalic = 7,
    Courier = 8,
    CourierBold = 9,
    CourierOblique = 10,
    CourierBoldOblique = 11,
}

/// <summary>How a line of text is shaped.</summary>
public enum TextDirection
{
    /// <summary>From the text itself (its first strong character).</summary>
    FromText = 0,
    LeftToRight = 1,
    RightToLeft = 2,
}
