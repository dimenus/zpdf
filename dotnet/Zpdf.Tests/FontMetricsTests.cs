using System;
using System.Buffers;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Xunit;

namespace Zpdf.Tests;

public sealed class FontMetricsTests
{
    private static byte[] TestFont() =>
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "TestFont.ttf"));

    [Fact]
    public void A_standard_font_measures_with_Adobes_widths()
    {
        using var helvetica = FontMetrics.Open(StandardFont.Helvetica);
        // H 722 + e 556 + l 222 + l 222 + o 556 = 2278 thousandths of the size.
        Assert.Equal(22.78, helvetica.Measure("Hello", 10, TextDirection.FromText), 9);
        Assert.Equal("NotWinAnsi", Assert.Throws<ZpdfException>(() => helvetica.Measure("一", 10, TextDirection.FromText)).ErrorName);
    }

    // The reader is the oracle here: it takes each run's width from the PDF's own /Widths, which
    // FontMetrics never sees.
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Measure_is_the_width_the_writer_draws(bool embedded)
    {
        const string text = "Total AVA office, 1,234.50";
        var output = new ArrayBufferWriter<byte>();
        double measured;
        using (var writer = PdfWriter.Create(output, compress: true))
        {
            using var metrics = embedded ? FontMetrics.Open(TestFont()) : FontMetrics.Open(StandardFont.TimesBold);
            var font = embedded ? writer.AddFont(TestFont()) : writer.AddStandardFont(StandardFont.TimesBold);
            measured = metrics.Measure(text, 11, TextDirection.FromText);
            var page = writer.BeginPage(612, 792);
            writer.DrawText(page, font, 11, 72, 720, PdfColor.Black, text, TextDirection.FromText);
            writer.EndPage(page);
            writer.Finish();
        }
        using var reader = PdfReader.Open(output.WrittenSpan);
        var run = Assert.Single(reader.ReadText(0).Runs);
        Assert.Equal(text, run.Text);
        Assert.True(measured > 100, $"measured {measured}");
        // zpdf places every glyph at its exact shaped position, but a PDF width is whole
        // thousandths of an em, so the run the reader sees ends at the last glyph's rounded width:
        // within half a thousandth of the size. A standard font's widths are whole already.
        var tolerance = embedded ? 11 * 0.0005 : 1e-9;
        Assert.InRange(measured, run.Width!.Value - tolerance, run.Width!.Value + tolerance);
    }

    [Fact]
    public void Wrap_gives_UTF_16_offsets_and_each_lines_measured_width()
    {
        // Two-byte, three-byte and four-byte UTF-8 characters before and inside the lines, so a
        // byte offset passed through unconverted would land in the wrong place.
        const string text = "Ünïcödé wörds “quoted” 𝄞𝄞 and more words here\r\nnext paragraph";
        using var metrics = FontMetrics.Open(TestFont());
        var lines = new List<TextLine>();
        metrics.Wrap(text, 12, 90, breakWords: true, TextDirection.FromText, lines);

        Assert.True(lines.Count >= 4, $"{lines.Count} lines");
        var words = lines.SelectMany(l => text.Substring(l.Start, l.Length).Split(' ', StringSplitOptions.RemoveEmptyEntries));
        Assert.Equal(text.Split([' ', '\r', '\n'], StringSplitOptions.RemoveEmptyEntries), words);
        Assert.Equal("next paragraph", text.Substring(lines[^1].Start, lines[^1].Length));
        foreach (var line in lines)
        {
            var slice = text.AsSpan(line.Start, line.Length);
            Assert.False(slice.EndsWith(" "), $"line '{slice}' keeps its trailing space");
            Assert.Equal(metrics.Measure(slice, 12, TextDirection.FromText), line.Width, 9);
            Assert.InRange(line.Width, 0, 90);
        }
    }

    [Fact]
    public void A_word_wider_than_the_line_breaks_only_when_asked()
    {
        const string token = "SUPERCALIFRAGILISTICEXPIALIDOCIOUS-PART-NUMBER-000123";
        using var metrics = FontMetrics.Open(StandardFont.Helvetica);
        var lines = new List<TextLine>();

        metrics.Wrap(token, 8, 67, breakWords: false, TextDirection.FromText, lines);
        var whole = Assert.Single(lines);
        Assert.Equal(new TextLine(0, token.Length, metrics.Measure(token, 8, TextDirection.FromText)), whole);
        Assert.True(whole.Width > 67);

        metrics.Wrap(token, 8, 67, breakWords: true, TextDirection.FromText, lines);
        Assert.True(lines.Count > 1);
        Assert.Equal(token, string.Concat(lines.Select(l => token.Substring(l.Start, l.Length))));
        Assert.All(lines, l => Assert.InRange(l.Width, 0, 67));
    }

    [Fact]
    public void Wrapping_into_a_reused_list_allocates_nothing()
    {
        const string text = "one two three four five six seven eight nine ten eleven twelve";
        using var metrics = FontMetrics.Open(StandardFont.Helvetica);
        var lines = new List<TextLine>();
        metrics.Wrap(text, 10, 60, breakWords: true, TextDirection.FromText, lines);
        var count = lines.Count;
        Assert.True(count > 3);

        var before = GC.GetAllocatedBytesForCurrentThread();
        for (var i = 0; i < 100; i++)
        {
            metrics.Wrap(text, 10, 60, breakWords: true, TextDirection.FromText, lines);
        }
        var allocated = GC.GetAllocatedBytesForCurrentThread() - before;
        Assert.Equal(count, lines.Count);
        Assert.Equal(0, allocated);
        // And nothing stays behind in zpdf between calls.
        var live = metrics.LiveBytes();
        metrics.Wrap(text, 10, 60, breakWords: true, TextDirection.FromText, lines);
        Assert.Equal(live, metrics.LiveBytes());
    }

    [Theory]
    // Adobe's AFMs: Helvetica Ascender 718 Descender -207, Times 683 -217, Courier 629 -157.
    [InlineData(StandardFont.Helvetica, "Helvetica", 0.718, -0.207)]
    [InlineData(StandardFont.HelveticaBoldOblique, "Helvetica-BoldOblique", 0.718, -0.207)]
    [InlineData(StandardFont.TimesRoman, "Times-Roman", 0.683, -0.217)]
    [InlineData(StandardFont.TimesBoldItalic, "Times-BoldItalic", 0.683, -0.217)]
    [InlineData(StandardFont.Courier, "Courier", 0.629, -0.157)]
    [InlineData(StandardFont.CourierBoldOblique, "Courier-BoldOblique", 0.629, -0.157)]
    public void A_standard_font_has_its_AFM_name_and_vertical_metrics(StandardFont font, string name, double ascender, double descender)
    {
        using var metrics = FontMetrics.Open(font);
        Assert.Equal(name, metrics.Name);
        Assert.Equal(ascender, metrics.Ascender);
        Assert.Equal(descender, metrics.Descender);
    }

    [Fact]
    public void An_embedded_font_has_its_PostScript_name_and_hhea_metrics()
    {
        using var metrics = FontMetrics.Open(TestFont());
        Assert.Equal("Roboto-Regular", metrics.Name);
        // Roboto's hhea: ascender 1900, descender -500, 2048 units per em.
        Assert.Equal(1900.0 / 2048.0, metrics.Ascender);
        Assert.Equal(-500.0 / 2048.0, metrics.Descender);
    }

    [Fact]
    public void FirstMissing_is_a_UTF_16_index_or_the_length()
    {
        using var helvetica = FontMetrics.Open(StandardFont.Helvetica);
        Assert.Equal(1, helvetica.FirstMissing("a\U0001F600b", TextDirection.FromText));
        Assert.Equal(4, helvetica.FirstMissing("caf\u00E9\u20AC".AsSpan(0, 4), TextDirection.FromText));
        Assert.Equal(5, helvetica.FirstMissing("caf\u00E9\u20AC", TextDirection.FromText));
        Assert.Equal(2, helvetica.FirstMissing("ab\u0141", TextDirection.FromText));

        using var roboto = FontMetrics.Open(TestFont());
        // Roboto has Latin and Greek, and no CJK.
        Assert.Equal(7, roboto.FirstMissing("caf\u00E9 \u03A9 \u4E2D", TextDirection.FromText));
        Assert.Equal(3, roboto.FirstMissing("e\u0301x", TextDirection.FromText));
    }

    [Fact]
    public void Fit_keeps_the_longest_prefix_that_fits_and_its_width()
    {
        using var courier = FontMetrics.Open(StandardFont.Courier);
        // 600 thousandths a character: 6pt each at 10pt.
        Assert.Equal(3, courier.Fit("abcdef", 10, 20, TextDirection.FromText, out var width));
        Assert.Equal(18, width);
        Assert.Equal(6, courier.Fit("abcdef", 10, 36, TextDirection.FromText, out width));
        Assert.Equal(0, courier.Fit("abcdef", 10, 5.9, TextDirection.FromText, out width));
        Assert.Equal(0, width);
        Assert.Equal("InvalidNumber", Assert.Throws<ZpdfException>(() => courier.Fit("a", 10, -1, TextDirection.FromText, out _)).ErrorName);

        using var roboto = FontMetrics.Open(TestFont());
        // An emoji Roboto lacks is one .notdef glyph: the prefix never ends inside its surrogate pair.
        const string text = "ab\U0001F600cd";
        var through_emoji = roboto.Measure(text.AsSpan(0, 4), 12, TextDirection.FromText);
        Assert.Equal(4, roboto.Fit(text, 12, through_emoji, TextDirection.FromText, out width));
        Assert.Equal(through_emoji, width);
        Assert.Equal(2, roboto.Fit(text, 12, through_emoji - 0.01, TextDirection.FromText, out _));
    }

    [Fact]
    public void Fit_allocates_nothing()
    {
        const string text = "A long description of a stock item that is truncated in its column";
        using var helvetica = FontMetrics.Open(StandardFont.Helvetica);
        var kept = helvetica.Fit(text, 9, 80, TextDirection.FromText, out _);
        Assert.InRange(kept, 1, text.Length - 1);
        var before = GC.GetAllocatedBytesForCurrentThread();
        for (var i = 0; i < 100; i++)
        {
            helvetica.Fit(text, 9, 80, TextDirection.FromText, out _);
        }
        Assert.Equal(0, GC.GetAllocatedBytesForCurrentThread() - before);
    }

    [Fact]
    public void Courier_measures_600_thousandths_a_character_and_an_unknown_standard_font_is_refused()
    {
        using var metrics = FontMetrics.Open(StandardFont.Courier);
        Assert.Equal(6.0, metrics.Measure("abcdefghij", 1, TextDirection.FromText), 9);
        Assert.Equal("InvalidFont", Assert.Throws<ZpdfException>(() => FontMetrics.Open((StandardFont)12)).ErrorName);
    }
}
