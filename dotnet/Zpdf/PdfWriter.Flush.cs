using System;
using System.IO;
using System.IO.Pipelines;
using System.Threading;
using System.Threading.Tasks;

namespace Zpdf;

// The async part of PdfWriter: C# allows no await in an unsafe context, and the other part is
// unsafe for its pointers.
public sealed partial class PdfWriter
{
    /// <summary>
    /// Flushes what the writer put in <paramref name="writer"/> since the last flush. Throws
    /// <see cref="OperationCanceledException"/> for a cancelled flush, and
    /// <see cref="IOException"/> when the pipe's reader has stopped reading.
    /// </summary>
    public static async ValueTask FlushAsync(PipeWriter writer, CancellationToken cancellationToken)
    {
        var result = await writer.FlushAsync(cancellationToken).ConfigureAwait(false);
        if (result.IsCanceled)
        {
            throw new OperationCanceledException("the PipeWriter's flush was cancelled", cancellationToken);
        }
        if (result.IsCompleted)
        {
            throw new IOException("the PipeReader stopped reading before the PDF was written");
        }
    }
}
