using System.Net.Http.Json;
using System.Collections.Concurrent;

namespace PrasenzPrinter.Core.Logging;

// Best-effort forwarding never feeds its own failures back into the application log.
public sealed class NewRelicLogForwarder : IDisposable
{
    private readonly LogBuffer buffer;
    private readonly HttpClient client = new() { Timeout = TimeSpan.FromSeconds(10) };
    private readonly string licenseKey;
    private readonly ConcurrentQueue<LogEntry> pending = new();
    private readonly Timer timer;
    private readonly Action<LogEntry>? enqueue;
    public NewRelicLogForwarder(LogBuffer buffer, string licenseKey, string version)
    {
        this.buffer = buffer;
        this.licenseKey = licenseKey;
        if (!string.IsNullOrWhiteSpace(licenseKey))
        {
            enqueue = entry => pending.Enqueue(entry);
            buffer.Added += enqueue;
        }
        timer = new Timer(async _ => await FlushAsync(version), null, TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(10));
    }
    private async Task FlushAsync(string version)
    {
        if (string.IsNullOrWhiteSpace(licenseKey) || pending.IsEmpty) return;
        var batch = new List<LogEntry>();
        while (batch.Count < 100 && pending.TryDequeue(out var entry)) batch.Add(entry);
        if (batch.Count == 0) return;
        try
        {
            var attributes = new Dictionary<string, object?> { ["service.name"] = "prasenz-print-client", ["hostname"] = Environment.MachineName, ["version"] = version, ["platform"] = "windows" };
            using var request = new HttpRequestMessage(HttpMethod.Post, "https://log-api.newrelic.com/log/v1") { Content = JsonContent.Create(new[] { new { common = new { attributes }, logs = batch.Select(entry => new { timestamp = entry.Timestamp.ToUnixTimeMilliseconds(), message = entry.Message, attributes = new Dictionary<string, object?> { ["level"] = entry.Level, ["p-req-id"] = entry.RequestId } }) } }) };
            request.Headers.Add("Api-Key", licenseKey);
            await client.SendAsync(request);
        }
        catch { /* Logging transport is intentionally isolated from print delivery. */ }
    }
    public void Dispose()
    {
        timer.Dispose();
        if (enqueue is not null) buffer.Added -= enqueue;
        client.Dispose();
    }
}
