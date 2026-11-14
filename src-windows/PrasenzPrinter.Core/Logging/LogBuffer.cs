using System.Collections.Concurrent;

namespace PrasenzPrinter.Core.Logging;

public sealed record LogEntry(DateTimeOffset Timestamp, string Level, string Message, string? RequestId);

public sealed class LogBuffer
{
    private const int Capacity = 200;
    private readonly ConcurrentQueue<LogEntry> entries = new();
    public event Action<LogEntry>? Added;
    public IReadOnlyList<LogEntry> Entries => entries.ToArray();
    public void Write(string message, string level = "INFO", string? requestId = null)
    {
        var entry = new LogEntry(DateTimeOffset.UtcNow, level, message, requestId);
        entries.Enqueue(entry);
        while (entries.Count > Capacity) entries.TryDequeue(out _);
        Added?.Invoke(entry);
    }
}
