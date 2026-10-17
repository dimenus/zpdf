using System;
using System.Runtime.InteropServices;
using Xunit;
using Zpdf.Native;

namespace Zpdf.Tests;

public sealed class AbiTests
{
    [Fact]
    public void The_library_is_the_ABI_version_the_declarations_were_generated_for()
    {
        using var reader = PdfReader.Open(ReaderTests.Fixture("base.pdf"));
        Assert.Equal(ZpdfAbi.AbiVersion, ZpdfAbi.zpdf_abi_version());
    }

    // A field the generator mapped to a wider C# type would make the struct larger than the Size
    // zpdf gave it; StructLayout's Size cannot shrink a struct, so this sees it.
    [Fact]
    public void Each_wire_record_has_the_size_zpdf_gives_it()
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
            Assert.True(Marshal.SizeOf(type) == layout.Size, $"{type.Name}: {Marshal.SizeOf(type)} bytes, zpdf says {layout.Size}");
            count++;
        }
        Assert.True(count >= 8, $"{count} wire records checked");
    }
}
