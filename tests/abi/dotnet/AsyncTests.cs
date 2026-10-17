using System;
using System.Buffers;
using System.IO;
using System.IO.Pipelines;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using Zpdf.Native;

namespace Zpdf.AbiTest;

// The async tests: a separate part of Program, because C# allows no await in an unsafe context,
// and the other part is unsafe for its pointers.
internal static partial class Program
{
    // Renders into `writer` through a caller-buffer sink: after each page, and after finish,
    // `flush` is awaited (FlushAsync for a PipeWriter). `drawn` counts pages drawn.
    private static async Task RenderAsync(nint ctx, IBufferWriter<byte> writer, Func<ValueTask> flush, StrongBox<int>? drawn = null)
    {
        using var sink = new ZpdfBufferSink(writer);
        var doc = NewSinkDocument(ctx, sink);
        try
        {
            for (var p = 0; p < AsyncPages; p++)
            {
                EndPage(ctx, doc, DrawPage(ctx, doc, p), sink);
                if (drawn != null)
                {
                    drawn.Value++;
                }
                await flush();
            }
            Expect(Finish(ctx, doc, sink).Length == 0, "a sink document's finish gave bytes back");
            await flush();
        }
        finally
        {
            CloseDocument(ctx, doc);
        }
    }

    private static async Task AsyncSameBytes(nint ctx)
    {
        var want = BufferedBytes(ctx);
        var stream = new MemoryStream();
        var to_stream = PipeWriter.Create(stream, new StreamPipeWriterOptions(leaveOpen: true));
        await RenderAsync(ctx, to_stream, () => ZpdfBufferSink.FlushAsync(to_stream, CancellationToken.None));
        await to_stream.CompleteAsync();
        Expect(stream.ToArray().AsSpan().SequenceEqual(want), $"stream: {stream.Length} bytes, buffered {want.Length}");

        var pipe = new Pipe();
        var read = ReadAllAsync(pipe.Reader, TimeSpan.Zero);
        await RenderAsync(ctx, pipe.Writer, () => ZpdfBufferSink.FlushAsync(pipe.Writer, CancellationToken.None));
        await pipe.Writer.CompleteAsync();
        var (got, _) = await read;
        Expect(got.AsSpan().SequenceEqual(want), $"pipe: {got.Length} bytes, buffered {want.Length}");
    }

    private static async Task AsyncDoesNotBlock(nint ctx)
    {
        var want = BufferedBytes(ctx);
        var stream = new GatedStream();
        var writer = PipeWriter.Create(stream, new StreamPipeWriterOptions(leaveOpen: true));
        var drawn = new StrongBox<int>(0);
        var render = RenderAsync(ctx, writer, () => ZpdfBufferSink.FlushAsync(writer, CancellationToken.None), drawn);
        for (var p = 0; p < AsyncPages; p++)
        {
            await Until(stream.NextFlush(), render);
            // The page's flush is pending: rendering waits for it without blocking this thread,
            // and has not drawn the next page.
            Expect(!render.IsCompleted, $"page {p}: the render finished while a flush was pending");
            Expect(drawn.Value == p + 1, $"page {p}: {drawn.Value} pages drawn while its flush was pending");
            stream.Release();
        }
        await Until(stream.NextFlush(), render);
        stream.Release();
        await render;
        await writer.CompleteAsync();
        Expect(stream.ToArray().AsSpan().SequenceEqual(want), $"gated: {stream.Length} bytes, buffered {want.Length}");
    }

    private static async Task AsyncSlowConsumer(nint ctx)
    {
        var want = BufferedBytes(ctx);
        const int threshold = 256;
        var pipe = new Pipe(new PipeOptions(pauseWriterThreshold: threshold, resumeWriterThreshold: threshold / 2));
        var read = ReadAllAsync(pipe.Reader, TimeSpan.FromMilliseconds(2));
        long largest_chunk = 0;
        await RenderAsync(ctx, pipe.Writer, () =>
        {
            largest_chunk = Math.Max(largest_chunk, pipe.Writer.UnflushedBytes);
            return ZpdfBufferSink.FlushAsync(pipe.Writer, CancellationToken.None);
        });
        await pipe.Writer.CompleteAsync();
        var (got, most_waiting) = await read;
        Expect(got.AsSpan().SequenceEqual(want), $"pipe: {got.Length} bytes, buffered {want.Length}");
        // Each flush puts in one page (or the end) whole, and waits while more than the
        // threshold waits: so at most the largest chunk plus the threshold. Without the wait it
        // would be the whole document.
        var page_bound = largest_chunk + threshold;
        Expect(most_waiting <= page_bound, $"{most_waiting} bytes waited in the pipe, more than the largest chunk plus the threshold ({page_bound})");
        Expect(want.Length > page_bound * 3, $"the document ({want.Length} bytes) is too small to show backpressure");
    }

    private static async Task AsyncCancellation(nint ctx)
    {
        var want = BufferedBytes(ctx);

        // A token cancelled before the flush: the bytes stay in the pipe, so the next flush sends
        // them and nothing is lost.
        var kept = new MemoryStream();
        var to_kept = PipeWriter.Create(kept, new StreamPipeWriterOptions(leaveOpen: true));
        var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        var first = true;
        await RenderAsync(ctx, to_kept, async () =>
        {
            if (first)
            {
                first = false;
                try
                {
                    await ZpdfBufferSink.FlushAsync(to_kept, cancelled.Token);
                    Expect(false, "a cancelled token did not throw");
                }
                catch (OperationCanceledException)
                {
                }
            }
            await ZpdfBufferSink.FlushAsync(to_kept, CancellationToken.None);
        });
        await to_kept.CompleteAsync();
        Expect(kept.ToArray().AsSpan().SequenceEqual(want), $"after an early cancel: {kept.Length} bytes, buffered {want.Length}");

        // Cancelled while a flush is pending: the caller gets OperationCanceledException, and the
        // document closes with none of the writer's memory held (WithContext checks the context).
        var stream = new GatedStream();
        var writer = PipeWriter.Create(stream, new StreamPipeWriterOptions(leaveOpen: true));
        var cts = new CancellationTokenSource();
        var render = RenderAsync(ctx, writer, () => ZpdfBufferSink.FlushAsync(writer, cts.Token));
        await Until(stream.NextFlush(), render);
        cts.Cancel();
        try
        {
            await render;
            Expect(false, "a cancelled pending flush did not throw");
        }
        catch (OperationCanceledException)
        {
        }
    }

    // Waits for `step`, unless the render ends first: then its failure is the test's, rather
    // than a wait that never ends.
    private static async Task Until(Task step, Task render)
    {
        if (await Task.WhenAny(step, render) == render)
        {
            await render;
            throw new InvalidOperationException("the render ended before the step the test waited for");
        }
    }

    // Reads a pipe to its end, pausing `delay` between reads; returns the bytes and the most that
    // waited unread at once.
    private static async Task<(byte[], long)> ReadAllAsync(PipeReader reader, TimeSpan delay)
    {
        var all = new MemoryStream();
        long most = 0;
        while (true)
        {
            if (delay > TimeSpan.Zero)
            {
                await Task.Delay(delay);
            }
            var result = await reader.ReadAsync();
            most = Math.Max(most, result.Buffer.Length);
            foreach (var segment in result.Buffer)
            {
                all.Write(segment.Span);
            }
            reader.AdvanceTo(result.Buffer.End);
            if (result.IsCompleted)
            {
                break;
            }
        }
        await reader.CompleteAsync();
        return (all.ToArray(), most);
    }

    // A stream whose flushes complete when the test says (a PipeWriter over it flushes it once per
    // FlushAsync): each FlushAsync waits for Release, or for its token.
    private sealed class GatedStream : MemoryStream
    {
        private readonly object _lock = new();
        private TaskCompletionSource _started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private TaskCompletionSource _gate = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public override async Task FlushAsync(CancellationToken ct)
        {
            Task gate;
            lock (_lock)
            {
                gate = _gate.Task;
                _started.TrySetResult();
            }
            await gate.WaitAsync(ct);
        }

        // Waits until a flush has started and waits at the gate.
        public async Task NextFlush()
        {
            Task started;
            lock (_lock)
            {
                started = _started.Task;
            }
            await started;
        }

        public void Release()
        {
            lock (_lock)
            {
                _started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var gate = _gate;
                _gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                gate.SetResult();
            }
        }
    }
}
