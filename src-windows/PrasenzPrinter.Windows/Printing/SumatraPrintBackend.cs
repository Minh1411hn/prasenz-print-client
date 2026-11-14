using System.Diagnostics;
using PrasenzPrinter.Core.Printing;

namespace PrasenzPrinter.Windows.Printing;

public sealed class SumatraPrintBackend(string executablePath, string jobsDirectory) : IPrintBackend
{
    private static readonly TimeSpan PrintTimeout = TimeSpan.FromMinutes(2);
    public async Task PrintAsync(PrintJob job, CancellationToken cancellationToken)
    {
        if (!File.Exists(executablePath)) throw new FileNotFoundException("SumatraPDF executable was not found", executablePath);
        Directory.CreateDirectory(jobsDirectory);
        var pdfPath = Path.Combine(jobsDirectory, Guid.NewGuid() + ".pdf");
        await File.WriteAllBytesAsync(pdfPath, job.Pdf, cancellationToken);
        try
        {
            using var process = new Process { StartInfo = BuildStartInfo(job, pdfPath), EnableRaisingEvents = true };
            if (!process.Start()) throw new InvalidOperationException("SumatraPDF did not start");
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(PrintTimeout);
            try { await process.WaitForExitAsync(timeout.Token); }
            catch (OperationCanceledException) { if (!process.HasExited) process.Kill(true); throw; }
            if (process.ExitCode != 0) throw new InvalidOperationException($"SumatraPDF exited with code {process.ExitCode}");
        }
        finally { try { File.Delete(pdfPath); } catch (IOException) { } }
    }
    private ProcessStartInfo BuildStartInfo(PrintJob job, string pdfPath)
    {
        var info = new ProcessStartInfo(executablePath) { UseShellExecute = false, CreateNoWindow = true };
        info.ArgumentList.Add("-print-to"); info.ArgumentList.Add(job.PrinterName);
        var settings = new List<string>();
        if (job.Options.FitToPage) settings.Add("fit");
        if (job.Options.NoScale) settings.Add("noscale");
        if (job.Options.Paper is not null) settings.Add("paper=" + job.Options.Paper);
        if (job.Options.Copies is not null) settings.Add("copies=" + job.Options.Copies);
        if (job.Options.Duplex is not null) settings.Add(job.Options.Duplex);
        if (settings.Count > 0) { info.ArgumentList.Add("-print-settings"); info.ArgumentList.Add(string.Join(',', settings)); }
        info.ArgumentList.Add("-silent"); info.ArgumentList.Add(pdfPath);
        return info;
    }
}
