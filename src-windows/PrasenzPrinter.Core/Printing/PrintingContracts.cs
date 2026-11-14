namespace PrasenzPrinter.Core.Printing;

public interface IPrinterCatalog { IReadOnlyList<string> GetPrinters(); }
public interface IPrintBackend { Task PrintAsync(PrintJob job, CancellationToken cancellationToken); }

public sealed record PrintJob(string PrinterName, byte[] Pdf, PrintOptions Options, string? RequestId);
public sealed record PrintOptions(bool FitToPage, bool NoScale, string? Paper, int? Copies, string? Duplex, bool HasZeroMargins)
{
    public static PrintOptions Default { get; } = new(true, false, null, null, null, false);
}
