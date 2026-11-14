using PrasenzPrinter.Core;
using PrasenzPrinter.Core.Configuration;
using PrasenzPrinter.Core.Logging;
using PrasenzPrinter.Core.Printing;
using PrasenzPrinter.Core.Tunnel;
using PrasenzPrinter.Windows.Printing;
using PrasenzPrinter.Windows.Network;

namespace PrasenzPrinter.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(true, $"Local\\PrasenzPrinter-{Environment.UserName}", out var firstInstance);
        var activateName = $"Local\\PrasenzPrinter-Activate-{Environment.UserName}";
        if (!firstInstance)
        {
            try { using var existing = EventWaitHandle.OpenExisting(activateName); existing.Set(); } catch (WaitHandleCannotBeOpenedException) { }
            return;
        }
        using var activateEvent = new EventWaitHandle(false, EventResetMode.AutoReset, activateName);
        ApplicationConfiguration.Initialize();
        var dataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PrasenzPrinter");
        var log = new LogBuffer();
        using var fileLog = new FileLogWriter(dataDirectory, log);
        var backend = new SumatraPrintBackend(Path.Combine(AppContext.BaseDirectory, "tools", "SumatraPDF.exe"), Path.Combine(dataDirectory, "jobs"));
        var queue = new PrintQueue(backend, (message, requestId, error) => log.Write(message, error ? "ERROR" : "INFO", requestId));
        var tunnel = new TunnelManager(Path.Combine(AppContext.BaseDirectory, "tools", "cloudflared.exe"), (message, error) => log.Write(message, error ? "ERROR" : "INFO"));
        using var network = new WindowsNetworkObserver(tunnel);
        var coordinator = new AppCoordinator(new SettingsStore(dataDirectory), queue, tunnel, log);
        try
        {
            coordinator.StartAsync().GetAwaiter().GetResult();
            Application.Run(new TrayApplicationContext(coordinator, log, new WindowsPrinterCatalog(), dataDirectory, activateEvent));
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "PrasenzPrinter startup error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally { coordinator.DisposeAsync().AsTask().GetAwaiter().GetResult(); }
    }
}
