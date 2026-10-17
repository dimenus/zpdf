using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Zpdf.Native;

namespace Zpdf;

/// <summary>
/// Measures and wraps text in one font, with the widths <see cref="PdfWriter.DrawText"/> draws.
/// </summary>
/// <remarks>
/// <para>
/// A standard font measures with Adobe's metrics, and its text must be WinAnsi (Latin-1 and a few
/// more); any other character throws a <see cref="ZpdfException"/> named <c>NotWinAnsi</c>, as
/// drawing it would. A font file measures shaped text, so kerning and ligatures count.
/// </para>
/// <para>
/// Wrap rules: a line breaks after a space or tab, and between CJK characters (not before closing
/// punctuation or after opening punctuation). A line break in the text (<c>\n</c>, <c>\r\n</c>,
/// <c>\r</c>) always breaks, and an empty paragraph is an empty line. The spaces a line ends with are
/// not part of it.
/// </para>
/// <para>
/// One thread at a time; each instance has its own zpdf context, like <see cref="PdfReader"/>.
/// </para>
/// </remarks>
public sealed unsafe class FontMetrics : IDisposable
{
    private readonly ContextHandle _context;
    private readonly uint _font;

    private FontMetrics(ContextHandle context, uint font)
    {
        _context = context;
        _font = font;
    }

    public static FontMetrics Open(StandardFont font)
    {
        var context = ContextHandle.Create();
        try
        {
            uint handle;
            ZpdfLibrary.Check(ZpdfAbi.zpdf_font_open_standard(context.Pointer, (uint)font, &handle));
            return new FontMetrics(context, handle);
        }
        catch
        {
            context.Dispose();
            throw;
        }
    }

    /// <summary>A TrueType or OpenType font (its first face, default instance), as
    /// <see cref="PdfWriter.AddFont"/> embeds it. zpdf copies the bytes.</summary>
    public static FontMetrics Open(ReadOnlySpan<byte> fontFile)
    {
        var context = ContextHandle.Create();
        try
        {
            uint handle;
            fixed (byte* bytes = fontFile)
            {
                ZpdfLibrary.Check(ZpdfAbi.zpdf_font_open(context.Pointer, bytes, (nuint)fontFile.Length, 0, null, 0, &handle));
            }
            return new FontMetrics(context, handle);
        }
        catch
        {
            context.Dispose();
            throw;
        }
    }

    /// <summary>The width of <paramref name="text"/> drawn as one line at <paramref name="size"/>
    /// points, in points.</summary>
    public double Measure(ReadOnlySpan<char> text, double size, TextDirection direction)
    {
        var context = Enter();
        Span<byte> stack = stackalloc byte[PdfWriter.StackTextBytes];
        var utf8 = PdfWriter.Encode(text, stack, out var rented);
        try
        {
            double width;
            fixed (byte* bytes = utf8)
            {
                ZpdfLibrary.Check(ZpdfAbi.zpdf_font_measure(context, _font, size, bytes, (nuint)utf8.Length, (uint)direction, &width));
            }
            return width;
        }
        finally
        {
            PdfWriter.Return(rented);
        }
    }

    /// <summary>
    /// Replaces the contents of <paramref name="lines"/> with the lines <paramref name="text"/>
    /// wraps to at <paramref name="maxWidth"/> points. Empty text gives no lines. A word wider than
    /// the line is broken between characters when <paramref name="breakWords"/> is true (never
    /// inside a surrogate pair, or before a combining mark or an emoji modifier); otherwise it
    /// stands alone on a line wider than <paramref name="maxWidth"/>, which the caller can see in
    /// <see cref="TextLine.Width"/>.
    /// </summary>
    /// <remarks>The caller's list is reused so that wrapping many cells allocates nothing per
    /// call once it has grown.</remarks>
    public void Wrap(ReadOnlySpan<char> text, double size, double maxWidth, bool breakWords, TextDirection direction, List<TextLine> lines)
    {
        ArgumentNullException.ThrowIfNull(lines);
        var context = Enter();
        lines.Clear();
        Span<byte> stack = stackalloc byte[PdfWriter.StackTextBytes];
        var utf8 = PdfWriter.Encode(text, stack, out var rented);
        try
        {
            byte* buffer;
            nuint length;
            fixed (byte* bytes = utf8)
            {
                ZpdfLibrary.Check(ZpdfAbi.zpdf_font_wrap(context, _font, size, bytes, (nuint)utf8.Length, (uint)direction, maxWidth, breakWords ? 1u : 0u, &buffer, &length));
            }
            try
            {
                Decode(new ReadOnlySpan<byte>(buffer, checked((int)length)), text, utf8, lines);
            }
            finally
            {
                ZpdfLibrary.Check(ZpdfAbi.zpdf_free(context, buffer, length));
            }
        }
        finally
        {
            PdfWriter.Return(rented);
        }
    }

    // zpdf_font_wrap's wire form: a WrapHeader, then line_count LineRecords whose start and len
    // are UTF-8 byte offsets, in increasing order. They become UTF-16 offsets into `text` in one
    // forward walk, so a line costs its own length and not the text's.
    private static void Decode(ReadOnlySpan<byte> wire, ReadOnlySpan<char> text, ReadOnlySpan<byte> utf8, List<TextLine> lines)
    {
        var header = MemoryMarshal.Read<WrapHeader>(wire);
        if (wire.Length != sizeof(WrapHeader) + checked((int)header.line_count * sizeof(LineRecord)))
        {
            throw new InvalidOperationException(
                $"zpdf_font_wrap returned {wire.Length} bytes, and its header describes {header.line_count} lines.");
        }
        var walk = new Utf16Walk(text, utf8.Length);
        for (var i = 0; i < (int)header.line_count; i++)
        {
            var line = MemoryMarshal.Read<LineRecord>(wire[(sizeof(WrapHeader) + i * sizeof(LineRecord))..]);
            var start = walk.To((int)line.start);
            var end = walk.To((int)(line.start + line.len));
            lines.Add(new TextLine(start, end - start, line.width));
        }
    }

    // Moves forward through `text` by UTF-8 byte offset and gives the matching UTF-16 offset. An
    // offset that is not on a character boundary, or that goes back, means zpdf and this code
    // disagree about the text, so it throws rather than guess.
    private ref struct Utf16Walk
    {
        private readonly ReadOnlySpan<char> _text;
        private readonly int _byteLength;
        private int _char;
        private int _byte;

        public Utf16Walk(ReadOnlySpan<char> text, int byteLength)
        {
            _text = text;
            _byteLength = byteLength;
        }

        public int To(int target)
        {
            if (target < _byte || target > _byteLength)
            {
                throw new InvalidOperationException($"zpdf_font_wrap gave byte offset {target}, at {_byte} of {_byteLength}.");
            }
            while (_byte < target)
            {
                var c = _text[_char];
                if (char.IsHighSurrogate(c))
                {
                    _char += 2;
                    _byte += 4;
                }
                else
                {
                    _char += 1;
                    _byte += c < 0x80 ? 1 : c < 0x800 ? 2 : 3;
                }
            }
            if (_byte != target)
            {
                throw new InvalidOperationException($"zpdf_font_wrap gave byte offset {target}, inside a character.");
            }
            return _char;
        }
    }

    private ZpdfContext* Enter()
    {
        ObjectDisposedException.ThrowIf(_context.IsClosed, this);
        return _context.Pointer;
    }

    // Live bytes in this context, for tests of what zpdf keeps between calls.
    internal nuint LiveBytes() => _context.LiveBytes();

    /// <summary>Frees the font and its native memory.</summary>
    public void Dispose() => _context.Free();
}

/// <summary>One wrapped line: <c>text.Slice(Start, Length)</c>, without its trailing spaces or its
/// line break, and its width in points.</summary>
public readonly record struct TextLine(int Start, int Length, double Width);
