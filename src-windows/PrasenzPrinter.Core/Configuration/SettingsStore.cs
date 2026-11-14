using System.Text.Json;

namespace PrasenzPrinter.Core.Configuration;

public sealed class SettingsStore(string dataDirectory)
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    public string DataDirectory { get; } = dataDirectory;
    public string SettingsPath => Path.Combine(DataDirectory, "settings.json");

    public async Task<AppSettings> LoadAsync(CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(DataDirectory);
        if (!File.Exists(SettingsPath)) return new AppSettings();
        await using var stream = File.OpenRead(SettingsPath);
        return (await JsonSerializer.DeserializeAsync<AppSettings>(stream, JsonOptions, cancellationToken) ?? new AppSettings()).Validate();
    }

    public async Task SaveAsync(AppSettings settings, CancellationToken cancellationToken = default)
    {
        settings.Validate();
        Directory.CreateDirectory(DataDirectory);
        var temporaryPath = SettingsPath + ".tmp";
        await File.WriteAllTextAsync(temporaryPath, JsonSerializer.Serialize(settings, JsonOptions), cancellationToken);
        File.Move(temporaryPath, SettingsPath, true);
    }
}
