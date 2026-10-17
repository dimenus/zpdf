using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Xunit;

namespace Zpdf.Tests;

public sealed class ReaderTests
{
    internal static byte[] Fixture(string name) =>
        File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", name));

    // What tools/read-fixtures.mjs draws on page n of base.pdf, in drawing order.
    private static (string Text, double X, double Y, double Size)[] FixturePage(int n) =>
    [
        ($"Report page {n}: office café", 76, 706, 14),
        ($"Helvetica (parens) \\ café €{n}", 76, 670, 10),
        ($"Page {n} of 3", 270, 30, 9),
    ];

    [Theory]
    [InlineData("base.pdf")]
    [InlineData("objstm.pdf")]
    [InlineData("linear.pdf")]
    public void Each_file_shape_reads_the_pages_and_text_the_fixture_drew(string file)
    {
        using var reader = PdfReader.Open(Fixture(file));

        Assert.Equal(3, reader.PageCount);
        for (var i = 0; i < reader.PageCount; i++)
        {
            var page = reader.GetPage(i);
            Assert.Equal(i, page.Index);
            Assert.Equal(new PdfBox(0, 0, 612, 792), page.MediaBox);
            Assert.Equal(page.MediaBox, page.CropBox);
            Assert.Equal(0, page.Rotation);

            var text = reader.ReadText(i);
            Assert.Equal(FixturePage(i + 1), text.Runs.Select(r => (r.Text, r.X, r.Y, r.Size)));
            Assert.EndsWith("+Roboto-Regular", text.Runs[0].Font);
            Assert.Equal("Helvetica", text.Runs[1].Font);
            Assert.All(text.Runs, r => Assert.True(r.UnmappedCodes == 0 && !r.IsActualText && r.Width > 0));
            Assert.Equal(0, text.UnplacedActualText);
        }
    }

    [Fact]
    public void Rotation_crop_box_actual_text_and_unmapped_codes_read_as_the_file_says()
    {
        using var reader = PdfReader.Open(HandMadePdf.Write());

        var page = reader.GetPage(0);
        Assert.Equal(new PdfBox(0, 0, 600, 800), page.MediaBox);
        Assert.Equal(new PdfBox(50, 60, 550, 760), page.CropBox);
        Assert.Equal(90, page.Rotation);

        var text = reader.ReadText(0);
        Assert.Equal(1, text.UnplacedActualText);
        Assert.Equal(2, text.Runs.Count);

        var actual = text.Runs[0];
        Assert.Equal("Hello", actual.Text);
        Assert.True(actual.IsActualText);
        Assert.Equal(0, actual.UnmappedCodes);
        Assert.Equal((100.0, 700.0, 12.0, "Helvetica"), (actual.X, actual.Y, actual.Size, actual.Font));

        var mystery = text.Runs[1];
        Assert.Equal("�B", mystery.Text);
        Assert.False(mystery.IsActualText);
        Assert.Equal(1, mystery.UnmappedCodes);
        Assert.Equal("Mystery", mystery.Font);
        // A font that is not standard and has no /Widths has no known advance.
        Assert.Null(mystery.Width);
    }

    [Fact]
    public void A_file_zpdf_cannot_read_throws_with_zpdfs_name_for_it()
    {
        Assert.Equal("Encrypted", Assert.Throws<ZpdfException>(() => PdfReader.Open(Fixture("encrypted.pdf"))).ErrorName);
        Assert.Equal("Malformed", Assert.Throws<ZpdfException>(() => PdfReader.Open("not a pdf"u8)).ErrorName);
    }

    [Fact]
    public void A_page_index_outside_the_file_and_a_disposed_reader_throw()
    {
        var reader = PdfReader.Open(Fixture("base.pdf"));

        Assert.Throws<ArgumentOutOfRangeException>(() => reader.ReadText(3));
        Assert.Throws<ArgumentOutOfRangeException>(() => reader.GetPage(-1));

        reader.Dispose();
        reader.Dispose();
        Assert.Throws<ObjectDisposedException>(() => reader.ReadText(0));
    }

    [Fact]
    public void Reading_a_page_keeps_nothing_of_it_once_it_returns()
    {
        using var reader = PdfReader.Open(Fixture("base.pdf"));
        for (var i = 0; i < reader.PageCount; i++)
        {
            reader.ReadText(i);
        }
        var after_first_pass = reader.LiveBytes();

        for (var pass = 0; pass < 20; pass++)
        {
            for (var i = 0; i < reader.PageCount; i++)
            {
                reader.ReadText(i);
                // Page i's text buffer is freed before ReadText returns.
                Assert.Equal(after_first_pass, reader.LiveBytes());
            }
        }
    }

    [Fact]
    public unsafe void Dispose_throws_when_zpdf_still_has_a_buffer_out()
    {
        var reader = PdfReader.Open(Fixture("base.pdf"));
        Assert.NotEqual(IntPtr.Zero, (IntPtr)Native.ZpdfAbi.zpdf_alloc(reader.ContextForTests, 16));

        Assert.Equal("BuffersOutstanding", Assert.Throws<ZpdfException>(reader.Dispose).ErrorName);
    }

    [Fact]
    public async Task Two_readers_on_two_threads_read_the_same_text()
    {
        var pdf = Fixture("objstm.pdf");
        static List<string> ReadAll(byte[] bytes)
        {
            using var reader = PdfReader.Open(bytes);
            return Enumerable.Range(0, reader.PageCount).SelectMany(p => reader.ReadText(p).Runs.Select(r => r.Text)).ToList();
        }

        var results = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => Task.Run(() =>
        {
            var last = new List<string>();
            for (var i = 0; i < 50; i++)
            {
                last = ReadAll(pdf);
            }
            return last;
        })));

        var want = ReadAll(pdf);
        Assert.All(results, r => Assert.Equal(want, r));
    }
}
