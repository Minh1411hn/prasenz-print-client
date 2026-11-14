using System.Diagnostics;

namespace PrasenzPrinter.Core.Tunnel;

public enum TunnelStatus { Disconnected, Connecting, Connected, Error }
public sealed record TunnelSnapshot(TunnelStatus Status, string ErrorMessage)
{
    public bool IsActive => Status == TunnelStatus.Connected;
}

public sealed class TunnelManager(string executablePath, Action<string, bool>? log = null) : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly CancellationTokenSource stopping = new();
    private Process? process;
    private string token = "";
    private int generation;
    private bool stoppedByUser;
    private int backoffSeconds = 3;
    public TunnelSnapshot Snapshot { get; private set; } = new(TunnelStatus.Disconnected, "");
    public event Action<TunnelSnapshot>? Changed;

    public Task StartAsync(string newToken) { lock (gate) { token = newToken; stoppedByUser = false; generation++; StopProcessLocked(); if (string.IsNullOrWhiteSpace(token)) SetLocked(TunnelStatus.Disconnected, ""); else _ = LaunchAsync(generation); } return Task.CompletedTask; }
    public Task RestartAsync() => StartAsync(token);
    public Task StopAsync() { lock (gate) { stoppedByUser = true; generation++; StopProcessLocked(); SetLocked(TunnelStatus.Disconnected, ""); } return Task.CompletedTask; }
    private async Task LaunchAsync(int processGeneration)
    {
        if (!File.Exists(executablePath)) { lock (gate) if (processGeneration == generation) SetLocked(TunnelStatus.Error, "cloudflared executable file not found"); return; }
        Process started;
        lock (gate)
        {
            if (processGeneration != generation || stoppedByUser) return;
            SetLocked(TunnelStatus.Connecting, "");
            started = new Process { StartInfo = new ProcessStartInfo(executablePath) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true } };
            started.StartInfo.ArgumentList.Add("tunnel"); started.StartInfo.ArgumentList.Add("run"); started.StartInfo.ArgumentList.Add("--token"); started.StartInfo.ArgumentList.Add(token);
            try { started.Start(); process = started; } catch (Exception error) { SetLocked(TunnelStatus.Error, error.Message); _ = RetryAsync(processGeneration); return; }
        }
        _ = DrainAsync(started.StandardOutput, processGeneration);
        _ = DrainAsync(started.StandardError, processGeneration);
        try { await started.WaitForExitAsync(stopping.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (stopping.IsCancellationRequested) { return; }
        lock (gate)
        {
            if (processGeneration != generation) return;
            process = null;
            if (!stoppedByUser) { SetLocked(TunnelStatus.Error, "Tunnel process exited; reconnecting"); _ = RetryAsync(processGeneration); }
        }
    }
    private async Task DrainAsync(StreamReader reader, int processGeneration)
    {
        while (await reader.ReadLineAsync(stopping.Token).ConfigureAwait(false) is { } line)
        {
            log?.Invoke("[cloudflared] " + line, false);
            if (line.Contains("registered", StringComparison.OrdinalIgnoreCase) || line.Contains("connection", StringComparison.OrdinalIgnoreCase) && line.Contains("established", StringComparison.OrdinalIgnoreCase)) lock (gate) if (processGeneration == generation) { backoffSeconds = 3; SetLocked(TunnelStatus.Connected, ""); }
        }
    }
    private async Task RetryAsync(int processGeneration)
    {
        int delay; lock (gate) { delay = backoffSeconds; backoffSeconds = Math.Min(backoffSeconds * 2, 30); }
        try { await Task.Delay(TimeSpan.FromSeconds(delay), stopping.Token); } catch (OperationCanceledException) { return; }
        lock (gate) if (processGeneration == generation && !stoppedByUser) _ = LaunchAsync(processGeneration);
    }
    private void StopProcessLocked() { if (process is { HasExited: false }) { try { process.Kill(true); } catch (InvalidOperationException) { } } process?.Dispose(); process = null; }
    private void SetLocked(TunnelStatus status, string error) { Snapshot = new TunnelSnapshot(status, error); Changed?.Invoke(Snapshot); }
    public async ValueTask DisposeAsync() { await StopAsync(); stopping.Cancel(); stopping.Dispose(); }
}
