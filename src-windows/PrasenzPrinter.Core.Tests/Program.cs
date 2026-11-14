using PrasenzPrinter.Core.Configuration;
using PrasenzPrinter.Core.Http;
using PrasenzPrinter.Core.Printing;
using PrasenzPrinter.Core.Tunnel;

var tests = new (string Name, Func<Task> Run)[]
{
    ("options default", () => { Assert(LegacyPrintOptionsParser.Parse(null, false).FitToPage); return Task.CompletedTask; }),
    ("options mapping", () => { var parsed = LegacyPrintOptionsParser.Parse("-o media=A4 -o scaling=100 -n 2 -o sides=two-sided-long-edge", true); Assert(parsed.Paper == "A4" && parsed.NoScale && parsed.Copies == 2 && parsed.Duplex == "duplexlong"); return Task.CompletedTask; }),
    ("unsupported options", () => { AssertThrows(() => LegacyPrintOptionsParser.Parse("-o landscape", true)); return Task.CompletedTask; }),
    ("settings validation", () => { AssertThrows(() => new AppSettings { PORT = "80" }.Validate()); return Task.CompletedTask; }),
    ("per-printer FIFO", QueueIsFifo),
    ("HTTP contract", HttpContract),
};
foreach (var test in tests) { await test.Run(); Console.WriteLine($"PASS {test.Name}"); }

static async Task QueueIsFifo()
{
    var printed = new List<string>();
    await using var queue = new PrintQueue(new FakeBackend(printed));
    queue.Enqueue(new PrintJob("one", [1], PrintOptions.Default, "first"));
    queue.Enqueue(new PrintJob("one", [2], PrintOptions.Default, "second"));
    queue.Enqueue(new PrintJob("two", [3], PrintOptions.Default, "other"));
    await Task.Delay(100);
    Assert(printed.IndexOf("first") < printed.IndexOf("second"));
}
static async Task HttpContract()
{
    var port = 39187;
    var printed = new List<string>();
    await using var queue = new PrintQueue(new FakeBackend(printed));
    await using var server = new PrintHttpServer(queue, () => new TunnelSnapshot(TunnelStatus.Disconnected, ""), "test", DateTimeOffset.UtcNow);
    await server.StartAsync(port, false);
    using var client = new HttpClient { BaseAddress = new Uri($"http://localhost:{port}") };
    using var missing = await client.PostAsync("/print", new ByteArrayContent([1]));
    Assert((int)missing.StatusCode == 400 && (await missing.Content.ReadAsStringAsync()).Contains("Missing x-printer-name header", StringComparison.Ordinal));
    using var request = new HttpRequestMessage(HttpMethod.Post, "/print") { Content = new ByteArrayContent([1]) };
    request.Headers.Add("X-Printer-Name", "fixture printer"); request.Headers.Add("P-Req-Id", "contract");
    using var success = await client.SendAsync(request);
    Assert((int)success.StatusCode == 200 && (await success.Content.ReadAsStringAsync()).Contains("Successfully enqueued print job", StringComparison.Ordinal));
    using var unknown = await client.GetAsync("/unknown"); Assert((int)unknown.StatusCode == 404);
    using var wrongMethod = await client.GetAsync("/print"); Assert((int)wrongMethod.StatusCode == 404);
}
static void Assert(bool value) { if (!value) throw new InvalidOperationException("Assertion failed"); }
static void AssertThrows(Action action) { try { action(); } catch (InvalidOperationException) { return; } throw new InvalidOperationException("Expected exception"); }
file sealed class FakeBackend(List<string> printed) : IPrintBackend { public Task PrintAsync(PrintJob job, CancellationToken cancellationToken) { lock (printed) printed.Add(job.RequestId!); return Task.CompletedTask; } }
