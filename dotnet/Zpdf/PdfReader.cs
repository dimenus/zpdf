using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using Zpdf.Native;

namespace Zpdf;

/// <summary>
/// Reads a PDF's pages and the text each page draws, one page at a time.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="Open"/> copies the file into native memory, so the caller's bytes can go once it
/// returns. Each <see cref="ReadText"/> reads one page and frees zpdf's memory for it before it
/// returns: memory follows one page, not the document.
/// </para>
/// <para>
/// One thread at a time. A reader has its own zpdf context, so two readers can be used on two
/// threads at once; one reader used by two threads at once fails with a
/// <see cref="ZpdfException"/> named <c>ContextBusy</c>.
/// </para>
/// <para>
/// Coordinates are PDF default user space: points, y up from the bottom of the page.
/// </para>
/// </remarks>
public sealed unsafe class PdfReader : IDisposable
{
    private readonly ContextHandle _context;
    private readonly uint _reader;

    private PdfReader(ContextHandle context, uint reader, int pageCount)
    {
        _context = context;
        _reader = reader;
        PageCount = pageCount;
    }

    /// <summary>Opens <paramref name="pdf"/>. An encrypted file opens when it needs no password,
    /// as most do. Throws <see cref="ZpdfException"/> for a file zpdf cannot read:
    /// <c>PasswordRequired</c>, <c>UnsupportedEncryption</c>, <c>Malformed</c> and others.</summary>
    public static PdfReader Open(ReadOnlySpan<byte> pdf)
    {
        var context = ContextHandle.Create();
        try
        {
            uint reader;
            uint count;
            fixed (byte* bytes = pdf)
            {
                ZpdfLibrary.Check(ZpdfAbi.zpdf_reader_open(context.Pointer, bytes, (nuint)pdf.Length, &reader));
            }
            ZpdfLibrary.Check(ZpdfAbi.zpdf_reader_page_count(context.Pointer, reader, &count));
            return new PdfReader(context, reader, checked((int)count));
        }
        catch
        {
            // The reader handle, when there is one, goes with its context.
            context.Dispose();
            throw;
        }
    }

    public int PageCount { get; }

    /// <summary>Page <paramref name="index"/>'s boxes and rotation (from 0).</summary>
    public PdfPage GetPage(int index)
    {
        var context = Enter(index);
        PageInfo info;
        ZpdfLibrary.Check(ZpdfAbi.zpdf_reader_page(context, _reader, (uint)index, &info));
        return new PdfPage(
            index,
            new PdfBox(info.media_box[0], info.media_box[1], info.media_box[2], info.media_box[3]),
            new PdfBox(info.crop_box[0], info.crop_box[1], info.crop_box[2], info.crop_box[3]),
            checked((int)info.rotate));
    }

    /// <summary>
    /// The text page <paramref name="index"/> draws, as runs in the order the page draws them. A
    /// page zpdf cannot read throws <see cref="ZpdfException"/>, and the other pages stay readable.
    /// </summary>
    public PageText ReadText(int index)
    {
        var context = Enter(index);
        byte* buffer;
        nuint length;
        ZpdfLibrary.Check(ZpdfAbi.zpdf_reader_page_text(context, _reader, (uint)index, &buffer, &length));
        try
        {
            return Decode(new ReadOnlySpan<byte>(buffer, checked((int)length)));
        }
        finally
        {
            ZpdfLibrary.Check(ZpdfAbi.zpdf_free(context, buffer, length));
        }
    }

    // zpdf_reader_page_text's wire form: a TextHeader, run_count RunRecords, glyph_count
    // GlyphRecords, then strings_len bytes of UTF-8. Records are not aligned, so each is read with
    // MemoryMarshal.Read. Glyph positions are not part of this API, so they are skipped.
    private static PageText Decode(ReadOnlySpan<byte> wire)
    {
        var header = MemoryMarshal.Read<TextHeader>(wire);
        var runs_at = sizeof(TextHeader);
        var strings_at = runs_at + checked((int)header.run_count * sizeof(RunRecord) + (int)header.glyph_count * sizeof(GlyphRecord));
        if (wire.Length != strings_at + (int)header.strings_len)
        {
            throw new InvalidOperationException(
                $"zpdf_reader_page_text returned {wire.Length} bytes, and its header describes {strings_at + (int)header.strings_len}.");
        }
        var strings = wire[strings_at..];
        var runs = new TextRun[header.run_count];
        for (var i = 0; i < runs.Length; i++)
        {
            var run = MemoryMarshal.Read<RunRecord>(wire[(runs_at + i * sizeof(RunRecord))..]);
            runs[i] = new TextRun(
                Encoding.UTF8.GetString(strings.Slice((int)run.text_offset, (int)run.text_len)),
                Encoding.UTF8.GetString(strings.Slice((int)run.font_offset, (int)run.font_len)),
                run.x,
                run.y,
                run.size,
                double.IsNaN(run.width) ? null : run.width,
                checked((int)run.unmapped),
                (run.flags & 1) != 0);
        }
        return new PageText(runs, checked((int)header.unplaced_actual_text));
    }

    private ZpdfContext* Enter(int index)
    {
        ObjectDisposedException.ThrowIf(_context.IsClosed, this);
        ArgumentOutOfRangeException.ThrowIfNegative(index);
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(index, PageCount);
        return _context.Pointer;
    }

    // This reader's context, for tests that call zpdf in it directly.
    internal ZpdfContext* ContextForTests => _context.Pointer;

    // Live bytes in this reader's context, for tests of what zpdf keeps between calls.
    internal nuint LiveBytes() => _context.LiveBytes();

    /// <summary>Frees the reader and its native memory.</summary>
    public void Dispose() => _context.Free();
}

/// <summary>A page box, <c>[Left Bottom Right Top]</c> in points, with Left &lt;= Right and
/// Bottom &lt;= Top.</summary>
public readonly record struct PdfBox(double Left, double Bottom, double Right, double Top)
{
    public double Width => Right - Left;

    public double Height => Top - Bottom;
}

/// <param name="Index">From 0.</param>
/// <param name="CropBox">The media box when the page has none.</param>
/// <param name="Rotation">Degrees clockwise: 0, 90, 180 or 270.</param>
public sealed record PdfPage(int Index, PdfBox MediaBox, PdfBox CropBox, int Rotation);

/// <summary>One run of text a page draws: glyphs drawn in one text-showing operation with one
/// font and size.</summary>
/// <param name="Font">The font's /BaseFont, possibly empty.</param>
/// <param name="X">The origin of the run's first glyph.</param>
/// <param name="Width">The run's advance, or null when a glyph's width is unknown.</param>
/// <param name="UnmappedCodes">Codes with no Unicode mapping; each is U+FFFD in
/// <paramref name="Text"/>.</param>
/// <param name="IsActualText">The text is the span's /ActualText, which replaces what the glyphs
/// map to.</param>
public sealed record TextRun(
    string Text,
    string Font,
    double X,
    double Y,
    double Size,
    double? Width,
    int UnmappedCodes,
    bool IsActualText);

/// <param name="Runs">In the order the page draws them.</param>
/// <param name="UnplacedActualText">/ActualText spans that drew no glyph, so their text is in
/// no run.</param>
public sealed record PageText(IReadOnlyList<TextRun> Runs, int UnplacedActualText);
