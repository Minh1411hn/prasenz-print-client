using System.Drawing.Printing;
using PrasenzPrinter.Core.Printing;

namespace PrasenzPrinter.Windows.Printing;

public sealed class WindowsPrinterCatalog : IPrinterCatalog
{
    public IReadOnlyList<string> GetPrinters() => PrinterSettings.InstalledPrinters.Cast<string>().OrderBy(name => name, StringComparer.CurrentCulture).ToArray();
}
