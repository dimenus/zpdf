using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using Zpdf.Native;

namespace Zpdf;

// Loads libzpdf once, before the first call, and refuses a library built for another ABI.
// Every public entry point calls EnsureLoaded first.
internal static unsafe class ZpdfLibrary
{
    private static readonly object Gate = new();
    private static bool _loaded;

    public static void EnsureLoaded()
    {
        lock (Gate)
        {
            if (_loaded)
            {
                return;
            }
            NativeLibrary.SetDllImportResolver(typeof(ZpdfLibrary).Assembly, Resolve);
            var version = ZpdfAbi.zpdf_abi_version();
            if (version != ZpdfAbi.AbiVersion)
            {
                throw new InvalidOperationException(
                    $"libzpdf has ABI version {version}, and Zpdf was generated for {ZpdfAbi.AbiVersion}. "
                    + "The native library and Zpdf.Abi.g.cs come from different zpdf commits.");
            }
            _loaded = true;
        }
    }

    // A status from a zpdf call: 0, or a ZpdfException with zpdf's name for the code.
    public static void Check(int status)
    {
        if (status != 0)
        {
            throw new ZpdfException(status, ErrorName(status));
        }
    }

    public static string ErrorName(int code)
    {
        var name = ZpdfAbi.zpdf_error_name(code);
        return name == null ? $"code {code}" : Marshal.PtrToStringUTF8((IntPtr)name)!;
    }

    private static string RuntimeIdentifier()
    {
        var architecture = RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant();
        if (OperatingSystem.IsMacOS())
        {
            return $"osx-{architecture}";
        }
        if (OperatingSystem.IsLinux())
        {
            return $"linux-{architecture}";
        }
        if (OperatingSystem.IsWindows())
        {
            return $"win-{architecture}";
        }
        throw new PlatformNotSupportedException(RuntimeInformation.OSDescription);
    }

    private static string FileName() =>
        OperatingSystem.IsWindows() ? "zpdf.dll" : OperatingSystem.IsMacOS() ? "libzpdf.dylib" : "libzpdf.so";

    // Where a project reference or a RID-less run puts libzpdf (runtimes/<rid>/native beside the
    // app or this assembly). A package restore with a RID puts it beside the app, which the
    // default probing finds when this returns no handle.
    internal static IEnumerable<string> NativeCandidates()
    {
        var relative = Path.Combine("runtimes", RuntimeIdentifier(), "native", FileName());
        yield return Path.Combine(AppContext.BaseDirectory, relative);
        var assembly_dir = Path.GetDirectoryName(typeof(ZpdfLibrary).Assembly.Location);
        if (!string.IsNullOrEmpty(assembly_dir))
        {
            yield return Path.Combine(assembly_dir, relative);
            yield return Path.Combine(assembly_dir, FileName());
        }
    }

    private static IntPtr Resolve(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (libraryName != ZpdfAbi.LibraryName)
        {
            return IntPtr.Zero;
        }
        foreach (var candidate in NativeCandidates())
        {
            if (File.Exists(candidate))
            {
                return NativeLibrary.Load(candidate);
            }
        }
        return IntPtr.Zero;
    }
}
