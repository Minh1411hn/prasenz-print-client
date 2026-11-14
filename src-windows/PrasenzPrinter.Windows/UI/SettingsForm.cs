using PrasenzPrinter.Core;
using PrasenzPrinter.Core.Configuration;
using PrasenzPrinter.Core.Logging;
using PrasenzPrinter.Core.Printing;
using PrasenzPrinter.Windows.Startup;

namespace PrasenzPrinter.Windows.UI;

public sealed class SettingsForm : Form
{
    private readonly AppCoordinator coordinator;
    private readonly IPrinterCatalog printers;
    private readonly WindowsStartupManager startup = new();
    private readonly TextBox token = new() { UseSystemPasswordChar = true, Width = 360 };
    private readonly TextBox port = new() { Width = 100 };
    private readonly TextBox newRelic = new() { UseSystemPasswordChar = true, Width = 360 };
    private readonly CheckBox autostart = new() { Text = "Start with Windows", AutoSize = true };
    private readonly CheckBox bindLan = new() { Text = "Allow direct LAN access", AutoSize = true };
    private readonly ListBox printerList = new() { Width = 480, Height = 100 };
    private readonly TextBox logs = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Width = 480, Height = 180 };
    private readonly Label status = new() { AutoSize = true };
    public SettingsForm(AppCoordinator coordinator, LogBuffer log, IPrinterCatalog printers)
    {
        this.coordinator = coordinator; this.printers = printers;
        Text = "PrasenzPrinter settings"; Width = 540; Height = 620; FormBorderStyle = FormBorderStyle.FixedDialog; MaximizeBox = false;
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(12) };
        panel.Controls.AddRange([LabelFor("Cloudflare tunnel token"), token, LabelFor("Port"), port, LabelFor("New Relic license key (optional)"), newRelic, autostart, bindLan, new Label { Text = "Printers", AutoSize = true }, printerList]);
        var printerButtons = new FlowLayoutPanel { AutoSize = true }; var refresh = new Button { Text = "Refresh" }; refresh.Click += (_, _) => RefreshPrinters(); var copy = new Button { Text = "Copy selected" }; copy.Click += (_, _) => { if (printerList.SelectedItem is string name) Clipboard.SetText(name); }; printerButtons.Controls.AddRange([refresh, copy]); panel.Controls.Add(printerButtons);
        var actions = new FlowLayoutPanel { AutoSize = true }; var save = new Button { Text = "Save & Apply" }; save.Click += async (_, _) => await SaveAsync(); var restart = new Button { Text = "Restart tunnel" }; restart.Click += async (_, _) => await coordinator.ApplyAsync(coordinator.Settings); actions.Controls.AddRange([save, restart]); panel.Controls.Add(actions);
        panel.Controls.Add(status); panel.Controls.Add(new Label { Text = "Recent logs", AutoSize = true }); panel.Controls.Add(logs); Controls.Add(panel);
        token.Text = coordinator.Settings.TUNNEL_TOKEN; port.Text = coordinator.Settings.PORT; newRelic.Text = coordinator.Settings.NEW_RELIC_LICENSE_KEY; autostart.Checked = startup.IsEnabled; bindLan.Checked = coordinator.Settings.BIND_LAN;
        foreach (var entry in log.Entries) AppendLog(entry); log.Added += entry => { if (!IsDisposed) BeginInvoke(() => AppendLog(entry)); };
        RefreshPrinters(); UpdateStatus(); coordinator.Settings.Validate();
        FormClosing += (_, eventArgs) => { if (eventArgs.CloseReason == CloseReason.UserClosing) { eventArgs.Cancel = true; Hide(); } };
    }
    private static Label LabelFor(string text) => new() { Text = text, AutoSize = true };
    private void RefreshPrinters() { printerList.Items.Clear(); printerList.Items.AddRange(printers.GetPrinters().Cast<object>().ToArray()); }
    private async Task SaveAsync()
    {
        try
        {
            var settings = new AppSettings { TUNNEL_TOKEN = token.Text, PORT = port.Text, NEW_RELIC_LICENSE_KEY = newRelic.Text, START_WITH_WINDOWS = autostart.Checked, BIND_LAN = bindLan.Checked }.Validate();
            await coordinator.ApplyAsync(settings); startup.SetEnabled(settings.START_WITH_WINDOWS); UpdateStatus();
            MessageBox.Show("Settings applied.", "PrasenzPrinter", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        catch (Exception error) { MessageBox.Show(error.Message, "Could not apply settings", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
    private void UpdateStatus() => status.Text = $"HTTP: listening on {coordinator.Settings.PORT} | Tunnel: {coordinator.Settings.TUNNEL_TOKEN.Length > 0}";
    private void AppendLog(LogEntry entry) { logs.AppendText($"[{entry.Timestamp:HH:mm:ss}] [{entry.Level}] {(entry.RequestId is null ? "" : "[req:" + entry.RequestId + "] ")}{entry.Message}{Environment.NewLine}"); }
}
