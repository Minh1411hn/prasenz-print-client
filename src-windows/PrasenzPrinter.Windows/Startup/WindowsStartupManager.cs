using Microsoft.Win32;

namespace PrasenzPrinter.Windows.Startup;

public sealed class WindowsStartupManager
{
    private const string KeyPath = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    private const string ValueName = "PrasenzPrinter";
    public bool IsEnabled => Registry.CurrentUser.OpenSubKey(KeyPath)?.GetValue(ValueName) is string;
    public void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(KeyPath);
        if (enabled) key.SetValue(ValueName, $"\"{Application.ExecutablePath}\"");
        else key.DeleteValue(ValueName, false);
    }
}
