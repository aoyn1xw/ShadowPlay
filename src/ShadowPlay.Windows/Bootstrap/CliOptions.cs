namespace ShadowPlay.Windows.Bootstrap;

/// <summary>Parses the small command-line surface (used for diagnostics/smoke runs).</summary>
public sealed record CliOptions
{
    public bool SmokeTest { get; private init; }

    public int SmokeSeconds { get; private init; } = 10;

    public string? Folder { get; private init; }

    public int? Port { get; private init; }

    public static CliOptions Parse(string[] args)
    {
        var options = new CliOptions();
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i].ToLowerInvariant())
            {
                case "--smoke":
                    options = options with { SmokeTest = true };
                    break;
                case "--smoke-seconds" when i + 1 < args.Length && int.TryParse(args[++i], out var seconds):
                    options = options with { SmokeSeconds = Math.Clamp(seconds, 1, 300) };
                    break;
                case "--folder" when i + 1 < args.Length:
                    options = options with { Folder = args[++i] };
                    break;
                case "--port" when i + 1 < args.Length && int.TryParse(args[++i], out var port):
                    options = options with { Port = Math.Clamp(port, 0, 65535) };
                    break;
            }
        }

        return options;
    }
}
