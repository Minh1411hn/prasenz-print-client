namespace PrasenzPrinter.Core.Logging;

public sealed class FileLogWriter : IDisposable
{
    private const long MaximumBytes = 2 * 1024 * 1024;
    private readonly string path;
    private readonly object gate = new();
    public FileLogWriter(string dataDirectory, LogBuffer buffer)
    {
        var logsDirectory = Path.Combine(dataDirectory, "logs");
        Directory.CreateDirectory(logsDirectory);
        path = Path.Combine(logsDirectory, "prasenz-printer.log");
        buffer.Added += Write;
    }
    private void Write(LogEntry entry)
    {
        lock (gate)
        {
            if (File.Exists(path) && new FileInfo(path).Length >= MaximumBytes) File.Move(path, path + ".1", true);
            File.AppendAllText(path, $"[{entry.Timestamp:O}] [{entry.Level}] {(entry.RequestId is null ? "" : "[req:" + entry.RequestId + "] ")}{entry.Message}{Environment.NewLine}");
        }
    }
    public void Dispose() { }
}
