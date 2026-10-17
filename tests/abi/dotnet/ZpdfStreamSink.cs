using System;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;

namespace Zpdf.Native;

// A .NET Stream as a zpdf Sink: a document made with ZpdfAbi.zpdf_doc_new_sink(ctx, compress,
// &sink.Native, ...) writes the PDF into the stream as each page ends. Only the callback is
// adapted here; documents are used through ZpdfAbi as any other.
//
// Lifetime: dispose only after the document is closed (zpdf calls Write until zpdf_doc_close).
// Errors: Write never lets an exception cross into zpdf (that would end the process). It keeps the
// exception and returns -1, the document fails with SinkFailed, and ThrowIfFailed throws the
// stream's own exception with its stack trace.
internal sealed unsafe class ZpdfStreamSink : IDisposable
{
    private readonly Stream _stream;
    private GCHandle _self;
    private Exception? _failure;

    public ZpdfStreamSink(Stream stream)
    {
        _stream = stream;
        _self = GCHandle.Alloc(this);
    }

    // The Sink to pass to zpdf_doc_new_sink. zpdf copies it; `user` is this object's handle.
    public Sink Native => new() { user = (void*)GCHandle.ToIntPtr(_self), write = &Write };

    // After a zpdf call on this sink's document: throws what the stream threw, when the call
    // returned SinkFailed. Any other code is the caller's to check.
    public void ThrowIfFailed(int rc)
    {
        if (rc == (int)ZpdfError.SinkFailed && _failure != null)
        {
            var failure = _failure;
            _failure = null;
            ExceptionDispatchInfo.Capture(failure).Throw();
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static int Write(void* user, byte* bytes, nuint len)
    {
        var sink = (ZpdfStreamSink)GCHandle.FromIntPtr((IntPtr)user).Target!;
        try
        {
            // len is at most zpdf's 64 KiB sink buffer.
            sink._stream.Write(new ReadOnlySpan<byte>(bytes, checked((int)len)));
            return 0;
        }
        catch (Exception e)
        {
            sink._failure = e;
            return -1;
        }
    }

    public void Dispose()
    {
        if (_self.IsAllocated)
        {
            _self.Free();
        }
    }
}
