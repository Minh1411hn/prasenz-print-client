namespace PrasenzPrinter.Core.Configuration;

public sealed class AppSettings
{
    public const int CurrentSchemaVersion = 1;
    public int SCHEMA_VERSION { get; init; } = CurrentSchemaVersion;
    public string TUNNEL_TOKEN { get; init; } = "";
    public string PORT { get; init; } = "37588";
    public string NEW_RELIC_LICENSE_KEY { get; init; } = "";
    public bool START_WITH_WINDOWS { get; init; }
    public bool BIND_LAN { get; init; }

    public int Port => int.TryParse(PORT, out var port) ? port : 0;
    public AppSettings Validate()
    {
        if (SCHEMA_VERSION != CurrentSchemaVersion) throw new InvalidOperationException("Unsupported settings schema version");
        if (Port is < 1024 or > 65535) throw new InvalidOperationException("Port must be between 1024 and 65535");
        return this;
    }
}
