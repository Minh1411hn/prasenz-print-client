using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Hosting;
using PrasenzPrinter.Core.Printing;
using PrasenzPrinter.Core.Tunnel;

namespace PrasenzPrinter.Core.Http;

public sealed class PrintHttpServer(PrintQueue queue, Func<TunnelSnapshot> tunnel, string version, DateTimeOffset startedAt, Action<string, string?, bool>? log = null) : IAsyncDisposable
{
    private const int MaximumPdfBytes = 50 * 1024 * 1024;
    private WebApplication? app;
    public int Port { get; private set; }
    public async Task StartAsync(int port, bool bindLan, CancellationToken cancellationToken = default)
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.WebHost.UseUrls($"http://{(bindLan ? "0.0.0.0" : "localhost")}:{port}");
        var web = builder.Build();
        // The macOS listener treats unsupported methods as unknown routes, not 405s.
        web.Use(async (context, next) =>
        {
            await next(context);
            if (context.Response.StatusCode == StatusCodes.Status405MethodNotAllowed && !context.Response.HasStarted)
                await JsonAsync(context, StatusCodes.Status404NotFound, new { error = "Not Found" });
        });
        web.MapPost("/print", async context => await PrintAsync(context));
        web.MapGet("/health", async context => await HealthAsync(context));
        web.MapFallback(async context => await JsonAsync(context, 404, new { error = "Not Found" }));
        await web.StartAsync(cancellationToken);
        app = web; Port = port; log?.Invoke($"HTTP server listening on port {port}", null, false);
    }
    private async Task PrintAsync(HttpContext context)
    {
        var printer = context.Request.Headers["x-printer-name"].ToString();
        if (string.IsNullOrWhiteSpace(printer)) { await JsonAsync(context, 400, new { error = "Missing x-printer-name header" }); return; }
        byte[] pdf;
        try { pdf = await ReadBoundedAsync(context.Request.Body, context.RequestAborted); }
        catch (InvalidOperationException) { await JsonAsync(context, 413, new { error = "Input PDF exceeds the 50 MiB limit" }); return; }
        if (pdf.Length == 0) { await JsonAsync(context, 400, new { error = "Input PDF data is empty" }); return; }
        try
        {
            var hasOptions = context.Request.Headers.ContainsKey("x-print-options");
            var options = LegacyPrintOptionsParser.Parse(context.Request.Headers["x-print-options"].ToString(), hasOptions);
            var requestId = context.Request.Headers["p-req-id"].ToString();
            queue.Enqueue(new PrintJob(printer, pdf, options, string.IsNullOrEmpty(requestId) ? null : requestId));
            await JsonAsync(context, 200, new { success = true, message = "Successfully enqueued print job" });
        }
        catch (InvalidOperationException error) { await JsonAsync(context, 400, new { error = error.Message }); }
    }
    private async Task HealthAsync(HttpContext context)
    {
        var snapshot = tunnel();
        await JsonAsync(context, 200, new { status = "ok", version, arch = "x86_64", uptime = (int)(DateTimeOffset.UtcNow - startedAt).TotalSeconds, queueLength = queue.PendingCount, tunnelActive = snapshot.IsActive, tunnelStatus = snapshot.Status.ToString().ToLowerInvariant(), tunnelErrorMessage = snapshot.ErrorMessage });
    }
    private static async Task<byte[]> ReadBoundedAsync(Stream stream, CancellationToken cancellationToken)
    {
        await using var buffer = new MemoryStream(); var chunk = new byte[81920]; int read;
        while ((read = await stream.ReadAsync(chunk, cancellationToken)) > 0) { if (buffer.Length + read > MaximumPdfBytes) throw new InvalidOperationException(); await buffer.WriteAsync(chunk.AsMemory(0, read), cancellationToken); }
        return buffer.ToArray();
    }
    private static Task JsonAsync(HttpContext context, int status, object body) { context.Response.StatusCode = status; return context.Response.WriteAsJsonAsync(body); }
    public async ValueTask DisposeAsync() { if (app is not null) await app.DisposeAsync(); }
}
