using PrasenzPrinter.Core.Printing;
using PrasenzPrinter.Windows.Printing;

var directory = Path.Combine(Path.GetTempPath(), "PrasenzPrinter tests " + Guid.NewGuid());
var backend = new SumatraPrintBackend(Path.Combine(directory, "missing SumatraPDF.exe"), directory);
try
{
    await backend.PrintAsync(new PrintJob("Printer with spaces", [1], PrintOptions.Default, null), CancellationToken.None);
    throw new InvalidOperationException("Expected missing executable failure");
}
catch (FileNotFoundException) { Console.WriteLine("PASS missing SumatraPDF executable"); }
