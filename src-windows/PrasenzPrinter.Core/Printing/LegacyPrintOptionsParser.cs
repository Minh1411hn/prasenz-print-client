namespace PrasenzPrinter.Core.Printing;

public static class LegacyPrintOptionsParser
{
    public static PrintOptions Parse(string? value, bool headerPresent)
    {
        if (!headerPresent) return PrintOptions.Default;
        if (string.IsNullOrWhiteSpace(value)) return new PrintOptions(false, false, null, null, null, false);
        var tokens = value.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var fit = false; var noScale = false; string? paper = null; int? copies = null; string? duplex = null; var zeroMargins = false;
        for (var i = 0; i < tokens.Length; i++)
        {
            var token = tokens[i];
            if (token == "-n") { copies = ParseCopies(Next(tokens, ref i, "-n")); continue; }
            if (token != "-o") throw Unsupported(token);
            var option = Next(tokens, ref i, "-o");
            if (option == "fit-to-page") { fit = true; continue; }
            if (option == "scaling=100") { noScale = true; continue; }
            if (option.StartsWith("media=", StringComparison.Ordinal)) { paper = ParsePaper(option[6..]); continue; }
            if (option.StartsWith("copies=", StringComparison.Ordinal)) { copies = ParseCopies(option[7..]); continue; }
            if (option.StartsWith("sides=", StringComparison.Ordinal)) { duplex = ParseDuplex(option[6..]); continue; }
            if (option is "page-left=0" or "page-right=0" or "page-top=0" or "page-bottom=0") { zeroMargins = true; continue; }
            throw Unsupported(option);
        }
        if (fit && noScale) throw new InvalidOperationException("fit-to-page and scaling=100 cannot be combined");
        return new PrintOptions(fit, noScale, paper, copies, duplex, zeroMargins);
    }

    private static string Next(string[] tokens, ref int index, string name) => ++index < tokens.Length ? tokens[index] : throw new InvalidOperationException($"Missing value after {name}");
    private static int ParseCopies(string value) => int.TryParse(value, out var copies) && copies is >= 1 and <= 99 ? copies : throw new InvalidOperationException("copies must be between 1 and 99");
    private static string ParsePaper(string value) => value.ToLowerInvariant() switch { "a4" => "A4", "letter" => "letter", var custom when custom.StartsWith("custom_", StringComparison.Ordinal) => custom, _ => throw Unsupported("media=" + value) };
    private static string ParseDuplex(string value) => value switch { "one-sided" => "simplex", "two-sided-long-edge" => "duplexlong", "two-sided-short-edge" => "duplexshort", _ => throw Unsupported("sides=" + value) };
    private static InvalidOperationException Unsupported(string option) => new($"Unsupported x-print-options value: {option}");
}
