using System;
using System.Buffers;
using System.IO;
using System.IO.Pipelines;
using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Zpdf.Native;

// An IBufferWriter<byte> as a caller-buffer zpdf Sink: zpdf writes the PDF straight into the
// writer's memory (GetMemory, pinned for the call), and each commit is an Advance. No managed
// copy and no managed allocation per page: the bytes are made where they end up.
//
// Async, with a PipeWriter (for a Stream: PipeWriter.Create(stream)): zpdf fills the pipe's memory
// during a zpdf call, which does no I/O, and FlushAsync between calls sends it. Awaiting that flush
// after each page is the backpressure (it waits while the reader is behind) and the place a
// CancellationToken applies; zpdf holds none of the writer's memory between calls, so flushing
// then is allowed. A cancelled or failed flush leaves the document part-written: close it, and
// what to do with the partial PDF is the destination's owner's call.
//
// Lifetime: dispose after the document is closed. Errors: an exception from the writer never
// crosses into zpdf; it is kept, the zpdf call returns SinkFailed, and ThrowIfFailed throws it.
internal sealed class ZpdfBufferSink : IDisposable
{
    private readonly IBufferWriter<byte> _writer;
    private GCHandle _self;
    private MemoryHandle _pinned;
    private bool _lent;
    private Exception? _failure;

    public ZpdfBufferSink(IBufferWriter<byte> writer)
    {
        _writer = writer;
        _self = GCHandle.Alloc(this);
    }

    // The Sink to pass to zpdf_doc_new_sink.
    public unsafe Sink Native => new() { user = (void*)GCHandle.ToIntPtr(_self), get_buffer = &GetBuffer, commit = &Commit };

    // After a zpdf call on this sink's document: throws what the writer threw, when the call
    // returned SinkFailed.
    public void ThrowIfFailed(int rc)
    {
        if (rc == (int)ZpdfError.SinkFailed && _failure != null)
        {
            var failure = _failure;
            _failure = null;
            ExceptionDispatchInfo.Capture(failure).Throw();
        }
    }

    // After a zpdf call that wrote (end_page, finish): sends what zpdf put in the pipe. The
    // flush's own waiting is the backpressure.
    public static async ValueTask FlushAsync(PipeWriter writer, CancellationToken ct)
    {
        var result = await writer.FlushAsync(ct).ConfigureAwait(false);
        if (result.IsCanceled)
        {
            throw new OperationCanceledException("the PipeWriter's flush was cancelled");
        }
        if (result.IsCompleted)
        {
            throw new IOException("the PipeReader stopped reading before the PDF was written");
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static unsafe int GetBuffer(void* user, nuint minLen, byte** buffer, nuint* len)
    {
        var sink = (ZpdfBufferSink)GCHandle.FromIntPtr((IntPtr)user).Target!;
        try
        {
            // zpdf asks for at most 64 KiB, and gives each buffer back before it asks again.
            var memory = sink._writer.GetMemory(checked((int)minLen));
            sink._pinned = memory.Pin();
            sink._lent = true;
            *buffer = (byte*)sink._pinned.Pointer;
            *len = (nuint)memory.Length;
            return 0;
        }
        catch (Exception e)
        {
            sink._failure = e;
            return -1;
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static unsafe int Commit(void* user, nuint len)
    {
        var sink = (ZpdfBufferSink)GCHandle.FromIntPtr((IntPtr)user).Target!;
        try
        {
            sink._pinned.Dispose();
            sink._lent = false;
            sink._writer.Advance(checked((int)len));
            return 0;
        }
        catch (Exception e)
        {
            sink._failure = e;
            return -1;
        }
    }

    // Whether zpdf holds the writer's memory now: never between zpdf calls.
    public bool Lent => _lent;

    public void Dispose()
    {
        if (_lent)
        {
            _pinned.Dispose();
            _lent = false;
        }
        if (_self.IsAllocated)
        {
            _self.Free();
        }
    }
}
