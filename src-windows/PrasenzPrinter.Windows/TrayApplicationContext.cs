using PrasenzPrinter.Core;
using PrasenzPrinter.Core.Logging;
using PrasenzPrinter.Core.Printing;
using PrasenzPrinter.Windows.UI;

namespace PrasenzPrinter.Windows;

public sealed class TrayApplicationContext : ApplicationContext
{
    private readonly AppCoordinator coordinator;
    private readonly NotifyIcon icon;
    private SettingsForm? form;
    private readonly IPrinterCatalog printers;
    private readonly string dataDirectory;
    private readonly LogBuffer log;
    private readonly Control uiMarshaller = new();
    private readonly RegisteredWaitHandle activationRegistration;
    public TrayApplicationContext(AppCoordinator coordinator, LogBuffer log, IPrinterCatalog printers, string dataDirectory, EventWaitHandle activateEvent)
    {
        this.coordinator = coordinator; this.log = log; this.printers = printers; this.dataDirectory = dataDirectory;
        var menu = new ContextMenuStrip(); menu.Items.Add("Open settings", null, (_, _) => OpenSettings()); menu.Items.Add("Exit", null, (_, _) => ExitThread());
        icon = new NotifyIcon { Text = "PrasenzPrinter", Icon = SystemIcons.Application, Visible = true, ContextMenuStrip = menu };
        icon.MouseClick += (_, eventArgs) => { if (eventArgs.Button == MouseButtons.Left) OpenSettings(); };
        _ = uiMarshaller.Handle;
        activationRegistration = ThreadPool.RegisterWaitForSingleObject(activateEvent, (_, _) => { try { uiMarshaller.BeginInvoke(OpenSettings); } catch (InvalidOperationException) { } }, null, Timeout.Infinite, false);
        if (!File.Exists(Path.Combine(dataDirectory, "settings.json"))) OpenSettings();
    }
    private void OpenSettings() { if (form is null || form.IsDisposed) form = new SettingsForm(coordinator, log, printers); form.Show(); form.Activate(); }
    protected override void ExitThreadCore() { activationRegistration.Unregister(null); uiMarshaller.Dispose(); icon.Visible = false; icon.Dispose(); base.ExitThreadCore(); }
}
