using System.Collections.Concurrent;
using System.Threading.Channels;

namespace PrasenzPrinter.Core.Printing;

public sealed class PrintQueue(IPrintBackend backend, Action<string, string?, bool>? log = null) : IAsyncDisposable
{
    private readonly ConcurrentDictionary<string, PrinterQueue> queues = new(StringComparer.Ordinal);
    private readonly CancellationTokenSource stopping = new();
    public int PendingCount => queues.Values.Sum(queue => queue.PendingCount);

    public void Enqueue(PrintJob job) => queues.GetOrAdd(job.PrinterName, name => new PrinterQueue(name, backend, stopping.Token, log)).Enqueue(job);
    public async ValueTask DisposeAsync() { stopping.Cancel(); await Task.WhenAll(queues.Values.Select(queue => queue.Completion)); stopping.Dispose(); }

    private sealed class PrinterQueue
    {
        private readonly Channel<PrintJob> channel = Channel.CreateUnbounded<PrintJob>(new UnboundedChannelOptions { SingleReader = true });
        private int pending;
        public PrinterQueue(string name, IPrintBackend backend, CancellationToken cancellationToken, Action<string, string?, bool>? log)
        {
            Completion = Task.Run(async () =>
            {
                try
                {
                    await foreach (var job in channel.Reader.ReadAllAsync(cancellationToken))
                    {
                        Interlocked.Decrement(ref pending);
                        try { await backend.PrintAsync(job, cancellationToken); log?.Invoke($"Spooled print job for {name}", job.RequestId, false); }
                        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
                        catch (Exception error) { log?.Invoke($"Print job for {name} failed: {error.Message}", job.RequestId, true); }
                    }
                }
                catch (OperationCanceledException) { }
            }, CancellationToken.None);
        }
        public Task Completion { get; }
        public int PendingCount => Volatile.Read(ref pending);
        public void Enqueue(PrintJob job) { Interlocked.Increment(ref pending); if (!channel.Writer.TryWrite(job)) Interlocked.Decrement(ref pending); }
    }
}
