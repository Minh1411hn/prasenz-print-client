using Microsoft.Win32;
using System.Net.NetworkInformation;
using PrasenzPrinter.Core.Tunnel;

namespace PrasenzPrinter.Windows.Network;

public sealed class WindowsNetworkObserver : IDisposable
{
    private readonly TunnelManager tunnel;
    private readonly Timer debounce;
    public WindowsNetworkObserver(TunnelManager tunnel)
    {
        this.tunnel = tunnel;
        debounce = new Timer(_ => _ = tunnel.RestartAsync(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
    }
    private void OnNetworkChanged(object? sender, EventArgs args) => ScheduleReconnect();
    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs args) { if (args.Mode == PowerModes.Resume) ScheduleReconnect(); }
    private void ScheduleReconnect() => debounce.Change(TimeSpan.FromSeconds(3), Timeout.InfiniteTimeSpan);
    public void Dispose() { NetworkChange.NetworkAddressChanged -= OnNetworkChanged; SystemEvents.PowerModeChanged -= OnPowerModeChanged; debounce.Dispose(); }
}
