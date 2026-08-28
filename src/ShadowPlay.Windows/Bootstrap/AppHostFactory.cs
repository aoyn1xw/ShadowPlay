using System.IO;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using ShadowPlay.Core.Clips;
using ShadowPlay.Core.Devices;
using ShadowPlay.Core.Pairing;
using ShadowPlay.Core.Settings;
using ShadowPlay.Core.Validation;
using ShadowPlay.Windows.Infrastructure;
using ShadowPlay.Windows.Services;
using ShadowPlay.Windows.Tray;

namespace ShadowPlay.Windows.Bootstrap;

/// <summary>Composes the Generic Host / DI container used by both interactive and smoke modes.</summary>
public static class AppHostFactory
{
    public const string AppDataFolderName = "ShadowPlay";

    public static string DefaultBaseDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppDataFolderName);

    public static string LogsDirectory => Path.Combine(DefaultBaseDirectory, "logs");

    public static IHost Build(CliOptions cli)
    {
        var host = Host.CreateApplicationBuilder();

        // Logging: our own rotating file log; no console spam in a windowed app.
        host.Logging.ClearProviders();
        host.Logging.AddShadowPlayFileLog(LogsDirectory);

        var services = host.Services;

        services.AddSingleton(TimeProvider.System);
        services.AddSingleton<ISettingsStore>(_ => new JsonSettingsStore(DefaultBaseDirectory));
        services.AddSingleton<SettingsService>();
        services.AddSingleton<ISettingsService>(sp => sp.GetRequiredService<SettingsService>());
        services.AddSingleton<IFolderValidator, FolderValidator>();
        services.AddSingleton<ClipCatalog>();
        services.AddSingleton<IClipCatalog>(sp => sp.GetRequiredService<ClipCatalog>());
        services.AddSingleton<IClipStore>(sp => sp.GetRequiredService<ClipCatalog>());
        services.AddSingleton<ISecretGenerator, SecureTokenGenerator>();
        services.AddSingleton<IDeviceRegistry, DeviceRegistry>();
        services.AddSingleton<IPairingService, PairingService>();
        services.AddSingleton<IWindowsFirewallService, WindowsFirewallService>();
        services.AddSingleton<AppController>();

        services.AddSingleton(sp => new TrayIconService(sp.GetRequiredService<AppController>()));

        var app = host.Build();

        ApplyCliOverrides(app.Services.GetRequiredService<SettingsService>(), cli);

        return app;
    }

    private static void ApplyCliOverrides(SettingsService settings, CliOptions cli)
    {
        if (cli.Folder is null && cli.Port is null)
        {
            return;
        }

        settings.Update(data =>
        {
            if (cli.Folder is not null)
            {
                data.RecordingsFolder = Path.GetFullPath(cli.Folder);
            }

            if (cli.Port is not null)
            {
                data.Port = cli.Port.Value;
            }
        });
    }
}
