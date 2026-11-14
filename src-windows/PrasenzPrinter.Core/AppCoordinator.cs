using PrasenzPrinter.Core.Configuration;
using PrasenzPrinter.Core.Http;
using PrasenzPrinter.Core.Logging;
using PrasenzPrinter.Core.Printing;
using PrasenzPrinter.Core.Tunnel;

namespace PrasenzPrinter.Core;

public sealed class AppCoordinator : IAsyncDisposable
{
    private readonly SettingsStore settingsStore;
    private readonly PrintQueue queue;
    private readonly TunnelManager tunnel;
    private readonly LogBuffer log;
    private readonly DateTimeOffset startedAt = DateTimeOffset.UtcNow;
    private PrintHttpServer? server;
    private NewRelicLogForwarder? newRelic;
    private string newRelicLicenseKey = "";
    public AppSettings Settings { get; private set; } = new();
    public AppCoordinator(SettingsStore settingsStore, PrintQueue queue, TunnelManager tunnel, LogBuffer log) => (this.settingsStore, this.queue, this.tunnel, this.log) = (settingsStore, queue, tunnel, log);
    public async Task StartAsync(CancellationToken cancellationToken = default) { Settings = await settingsStore.LoadAsync(cancellationToken); await ApplyAsync(Settings, false, cancellationToken); }
    public async Task ApplyAsync(AppSettings settings, bool persist = true, CancellationToken cancellationToken = default)
    {
        settings.Validate();
        var previous = server;
        PrintHttpServer? candidate = null;
        var listenerChange = server is null || server.Port != settings.Port || Settings.BIND_LAN != settings.BIND_LAN;
        if (listenerChange)
        {
            candidate = CreateServer();
            if (server is not null && server.Port == settings.Port)
            {
                var oldSettings = Settings;
                await server.DisposeAsync();
                try { await candidate.StartAsync(settings.Port, settings.BIND_LAN, cancellationToken); }
                catch
                {
                    server = CreateServer();
                    await server.StartAsync(oldSettings.Port, oldSettings.BIND_LAN, cancellationToken);
                    throw;
                }
            }
            else await candidate.StartAsync(settings.Port, settings.BIND_LAN, cancellationToken);
        }
        try
        {
            if (persist) await settingsStore.SaveAsync(settings, cancellationToken);
        }
        catch
        {
            if (candidate is not null)
            {
                await candidate.DisposeAsync();
                if (previous is not null && previous.Port == settings.Port)
                {
                    server = CreateServer();
                    await server.StartAsync(Settings.Port, Settings.BIND_LAN, cancellationToken);
                }
                else server = previous;
            }
            throw;
        }
        server = candidate ?? server;
        Settings = settings;
        await tunnel.StartAsync(settings.TUNNEL_TOKEN);
        UpdateNewRelicForwarder(settings.NEW_RELIC_LICENSE_KEY);
        if (candidate is not null && previous is not null && previous.Port != settings.Port) await previous.DisposeAsync();
    }
    private PrintHttpServer CreateServer() => new(queue, () => tunnel.Snapshot, Version(), startedAt, (message, requestId, error) => log.Write(message, error ? "ERROR" : "INFO", requestId));
    private void UpdateNewRelicForwarder(string licenseKey)
    {
        if (string.Equals(licenseKey, newRelicLicenseKey, StringComparison.Ordinal)) return;
        var replacement = string.IsNullOrWhiteSpace(licenseKey) ? null : new NewRelicLogForwarder(log, licenseKey, Version());
        var previous = newRelic;
        newRelic = replacement;
        newRelicLicenseKey = licenseKey;
        previous?.Dispose();
    }
    private static string Version() => typeof(AppCoordinator).Assembly.GetName().Version?.ToString() ?? "0.0.0";
    public async ValueTask DisposeAsync() { newRelic?.Dispose(); if (server is not null) await server.DisposeAsync(); await tunnel.DisposeAsync(); await queue.DisposeAsync(); }
}
