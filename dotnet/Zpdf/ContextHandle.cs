using System;
using System.Runtime.InteropServices;
using Zpdf.Native;

namespace Zpdf;

// One zpdf context, owned by one PdfReader or PdfWriter. Freeing it closes every handle opened in
// it. Free (from Dispose) throws when zpdf refuses, because then the owner gave out a buffer it
// never freed; the finalizer path cannot throw, and reports it through SafeHandle's release-failed
// path instead.
internal sealed unsafe class ContextHandle : SafeHandle
{
    private ContextHandle()
        : base(IntPtr.Zero, ownsHandle: true)
    {
    }

    public static ContextHandle Create()
    {
        ZpdfLibrary.EnsureLoaded();
        var context = ZpdfAbi.zpdf_context_new();
        if (context == null)
        {
            throw new OutOfMemoryException("zpdf_context_new returned no context.");
        }
        var handle = new ContextHandle();
        handle.SetHandle((IntPtr)context);
        return handle;
    }

    public ZpdfContext* Pointer => (ZpdfContext*)handle;

    public override bool IsInvalid => handle == IntPtr.Zero;

    public void Free()
    {
        if (IsClosed)
        {
            return;
        }
        var status = ZpdfAbi.zpdf_context_free(Pointer);
        SetHandleAsInvalid();
        ZpdfLibrary.Check(status);
    }

    // Live bytes in this context, for tests of what zpdf keeps between calls.
    public nuint LiveBytes()
    {
        nuint live;
        ZpdfLibrary.Check(ZpdfAbi.zpdf_live_bytes(Pointer, &live));
        return live;
    }

    protected override bool ReleaseHandle() => ZpdfAbi.zpdf_context_free((ZpdfContext*)handle) == 0;
}
