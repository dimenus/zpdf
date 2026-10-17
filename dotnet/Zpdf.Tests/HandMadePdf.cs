using System.Collections.Generic;
using System.IO;
using System.Text;

namespace Zpdf.Tests;

// A one-page PDF written byte by byte, for what zpdf's fixtures do not
// have: a rotation and a crop box, /ActualText (placed on glyphs, and with no glyph), a code with
// no Unicode mapping, and a font with no widths.
internal static class HandMadePdf
{
    public static byte[] Write()
    {
        const string content =
            // ActualText over drawn glyphs: the run's text is "Hello", not what the codes map to.
            "/Span <</ActualText (Hello)>> BDC BT /F1 12 Tf 100 700 Td (Hxllo) Tj ET EMC\n"
            // ActualText with no glyph in it: counted, in no run.
            + "/Span <</ActualText (unplaced)>> BDC EMC\n"
            // F2 maps code 0x41 to a glyph name with no Unicode value, and has no /Widths.
            + "BT /F2 10 Tf 100 600 Td (AB) Tj ET\n";
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /CropBox [50 60 550 760] /Rotate 90 "
                + "/Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> /Contents 4 0 R >>",
            $"<< /Length {content.Length} >>\nstream\n{content}\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Mystery "
                + "/Encoding << /Differences [65 /zz.unknown 66 /B] >> >>",
        };

        var pdf = new StringBuilder("%PDF-1.7\n");
        var offsets = new List<int>();
        for (var i = 0; i < objects.Count; i++)
        {
            offsets.Add(pdf.Length);
            pdf.Append($"{i + 1} 0 obj\n{objects[i]}\nendobj\n");
        }
        var xref = pdf.Length;
        pdf.Append($"xref\n0 {objects.Count + 1}\n0000000000 65535 f \n");
        foreach (var offset in offsets)
        {
            pdf.Append($"{offset:D10} 00000 n \n");
        }
        pdf.Append($"trailer\n<< /Size {objects.Count + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        return Encoding.ASCII.GetBytes(pdf.ToString());
    }
}
