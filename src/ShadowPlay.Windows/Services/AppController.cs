using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using ShadowPlay.Api;
using ShadowPlay.Core.Clips;
using ShadowPlay.Core.Devices;
using ShadowPlay.Core.Models;
using ShadowPlay.Core.Networking;
using ShadowPlay.Core.Pairing;
using ShadowPlay.Core.Settings;
using ShadowPlay.Core.Validation;

namespace ShadowPlay.Windows.Services;

public enum SharingState
{
    NotConfigured,
    Paused,
    Starting,
    Running,
    Error,
}

public sealed record ControllerStatus(SharingState State, string? Detail = null, int Port = 0)
{
    public static readonly ControllerStatus NotConfigured = new(SharingState.NotConfigured);

    public static readonly ControllerStatus Paused = new(SharingState.Paused);
}

/// <summary>
/// UI-free coordinator. Owns the LAN API host and clip monitor lifetimes, pairing offers
/// and status transitions. WPF layers subscribe to <see cref="StateChanged"/> and marshal to the UI thread.
/// </summary>
public sealed class AppController : IAsyncDisposable
{
    private readonly ISettingsService _settings;
    private readonly IFolderValidator _validator;
    private readonly ClipCatalog _catalog;
    private readonly IPairingService _pairing;
    private readonly IDeviceRegistry _devices;
    private readonly IWindowsFirewallService _firewall;
    private readonly IClipPreviewProvider _clipPreview;
    private readonly ILogger<AppController>? _logger;

    private WebApplication? _apiApp;
    private ClipMonitorService? _monitor;
    private int _actualPort;

    public AppController(
        ISettingsService settings,
        IFolderValidator validator,
        ClipCatalog catalog,
        IPairingService pairing,
        IDeviceRegistry devices,
        IWindowsFirewallService firewall,
        IClipPreviewProvider clipPreview,
        ILogger<AppController>? logger = null)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _validator = validator ?? throw new ArgumentNullException(nameof(validator));
        _catalog = catalog ?? throw new ArgumentNullException(nameof(catalog));
        _pairing = pairing ?? throw new ArgumentNullException(nameof(pairing));
        _devices = devices ?? throw new ArgumentNullException(nameof(devices));
        _firewall = firewall ?? throw new ArgumentNullException(nameof(firewall));
        _clipPreview = clipPreview ?? throw new ArgumentNullException(nameof(clipPreview));
        _logger = logger;

        _catalog.Changed += () => StateChanged?.Invoke();
    }

    public event Action? StateChanged;

    public ControllerStatus Status { get; private set; } = ControllerStatus.NotConfigured;

    public FirewallStatus FirewallStatus { get; private set; } = new(
        FirewallRuleState.Unavailable,
        "Firewall status has not been checked yet.",
        false);

    public bool IsConfigured => !string.IsNullOrWhiteSpace(_settings.Current.RecordingsFolder);

    public string? RecordingsFolder => _settings.Current.RecordingsFolder;

    /// <summary>The persisted port (may differ from the live one while paused).</summary>
    public int ConfiguredPort => _settings.Current.Port;

    /// <summary>The persisted sharing preference.</summary>
    public bool SharingEnabledSetting => _settings.Current.SharingEnabled;

    public bool IsSharingRunning => Status.State == SharingState.Running || Status.State == SharingState.Starting;

    /// <summary>
    /// Applies folder + port + sharing preference from the settings dialog and
    /// restarts sharing so they take effect immediately. Returns false on failure
    /// (validation or bind error); <see cref="Status.Detail"/> carries a friendly message.
    /// </summary>
    public async Task<bool> ApplySettingsAsync(string? folder, int port, bool sharingEnabled)
    {
        var validation = _validator.Validate(folder);
        if (!validation.IsValid)
        {
            SetStatus(new ControllerStatus(SharingState.Error, validation.Error));
            return false;
        }

        if (port is < 1 or > 65535)
        {
            SetStatus(new ControllerStatus(SharingState.Error, "Port must be between 1 and 65535."));
            return false;
        }

        _settings.Update(data =>
        {
            data.RecordingsFolder = Path.GetFullPath(folder!);
            data.Port = port;
            data.SharingEnabled = sharingEnabled;
        });

        await RestartSharingAsync().ConfigureAwait(false);

        if (Status.State == SharingState.Error)
        {
            return false;
        }

        StateChanged?.Invoke();
        return true;
    }

    public async Task InitializeAsync()
    {
        var data = _settings.Current;
        if (string.IsNullOrWhiteSpace(data.RecordingsFolder))
        {
            SetStatus(ControllerStatus.NotConfigured);
            return;
        }

        if (!data.SharingEnabled)
        {
            SetStatus(ControllerStatus.Paused);
            return;
        }

        await StartSharingAsync().ConfigureAwait(false);
    }

    /// <summary>Validates a folder choice; saves it and restarts sharing when valid.</summary>
    public async Task<bool> SelectFolderAsync(string? path)
    {
        var result = _validator.Validate(path);
        if (!result.IsValid)
        {
            SetStatus(new ControllerStatus(SharingState.Error, result.Error));
            return false;
        }

        _settings.Update(data => data.RecordingsFolder = Path.GetFullPath(path!));
        await RestartSharingAsync().ConfigureAwait(false);
        return true;
    }

    public async Task StartSharingAsync()
    {
        var folder = RecordingsFolder;
        var validation = _validator.Validate(folder);
        if (!validation.IsValid)
        {
            SetStatus(new ControllerStatus(SharingState.Error, validation.Error));
            return;
        }

        SetStatus(new ControllerStatus(SharingState.Starting));

        try
        {
            await StopCoreAsync().ConfigureAwait(false);

            var data = _settings.Current;
            var serverInfo = new StaticServerInfo(data.ServerId, Environment.MachineName);

            var apiOptions = new LanApiOptions
            {
                Catalog = _catalog,
                Pairing = _pairing,
                Devices = _devices,
                ServerInfo = serverInfo,
                ClipPreview = _clipPreview,
                Port = data.Port,
            };

            var app = LanApiFactory.Build(apiOptions);
            await app.StartAsync().ConfigureAwait(false);

            var port = ResolvePort(app);
            if (port is null)
            {
                await app.StopAsync().ConfigureAwait(false);
                SetStatus(new ControllerStatus(SharingState.Error, "The sharing service could not start."));
                return;
            }

            _apiApp = app;
            _actualPort = port.Value;

            var listenerAddresses = GetServerAddresses(app);
            _logger?.LogInformation(
                "LAN API listening on {ListenerAddresses}; Kestrel bind is IPv4 wildcard (IPAddress.Any), configured port {Port}",
                string.Join(", ", listenerAddresses),
                _actualPort);

            var executablePath = Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName;
            if (!string.IsNullOrWhiteSpace(executablePath))
            {
                FirewallStatus = _firewall.Check(executablePath, _actualPort);
                _logger?.LogInformation(
                    "Firewall check for {ExecutablePath} TCP {Port}: {State}. {Detail} Private profile active: {PrivateProfileActive}",
                    executablePath,
                    _actualPort,
                    FirewallStatus.State,
                    FirewallStatus.Detail,
                    FirewallStatus.PrivateNetworkActive);
            }

            _monitor = new ClipMonitorService(
                () => _settings.Current.RecordingsFolder,
                _catalog,
                TimeProvider.System,
                logger: _logger,
                previewProvider: _clipPreview);
            _monitor.RootUnavailable += root =>
            {
                SetStatus(new ControllerStatus(SharingState.Error, "The recordings folder is currently unavailable. Clips stay paused until it returns."));
                StateChanged?.Invoke();
            };
            _monitor.RootRecovered += _ => SetStatus(new ControllerStatus(SharingState.Running, null, _actualPort));
            await _monitor.StartAsync().ConfigureAwait(false);

            // Fresh offer so the QR code in the UI is immediately usable.
            _pairing.NewPairingOffer();

            SetStatus(new ControllerStatus(SharingState.Running, null, _actualPort));
        }
        catch (Exception ex)
        {
            _logger?.LogError(ex, "Failed to start sharing");
            SetStatus(new ControllerStatus(SharingState.Error, DescribeStartError(ex)));
        }
    }

    public async Task PauseSharingAsync()
    {
        await StopCoreAsync().ConfigureAwait(false);
        _settings.Update(d => d.SharingEnabled = false);
        SetStatus(ControllerStatus.Paused);
    }

    public async Task ResumeSharingAsync()
    {
        _settings.Update(d => d.SharingEnabled = true);
        await StartSharingAsync().ConfigureAwait(false);
    }

    public async Task RestartSharingAsync()
    {
        await StopCoreAsync().ConfigureAwait(false);
        if (_settings.Current.SharingEnabled)
        {
            await StartSharingAsync().ConfigureAwait(false);
        }
        else
        {
            SetStatus(ControllerStatus.Paused);
        }
    }

    public async Task ToggleSharingAsync()
    {
        if (IsSharingRunning)
        {
            await PauseSharingAsync().ConfigureAwait(false);
        }
        else
        {
            await ResumeSharingAsync().ConfigureAwait(false);
        }
    }

    /// <summary>Builds the QR payload for the current (or a fresh) pairing offer.</summary>
    public string? BuildQrPayload(bool regenerate)
    {
        var offer = regenerate ? _pairing.NewPairingOffer() : _pairing.CurrentOffer;
        if (offer is null)
        {
            offer = _pairing.NewPairingOffer();
        }

        var endpoint = LocalIpLocator.FindBestEndpoint();
        var address = endpoint?.Address.ToString() ?? IPAddress.Loopback.ToString();
        _logger?.LogInformation(
            "Selected LAN interface {InterfaceName} with IPv4 {Address} for pairing QR (default gateway: {HasDefaultGateway})",
            endpoint?.InterfaceName ?? "loopback",
            address,
            endpoint?.HasDefaultGateway ?? false);
        var payload = new QrPayload
        {
            ServerId = _settings.Current.ServerId,
            ComputerName = Environment.MachineName,
            LanAddress = address,
            Port = _actualPort > 0 ? _actualPort : _settings.Current.Port,
            PairingCode = offer.Code,
        };

        StateChanged?.Invoke();
        return payload.ToJson();
    }

    public DateTimeOffset? PairingExpiresAt => _pairing.CurrentOffer?.ExpiresAtUtc;

    public IReadOnlyList<ClipEntry> CatalogSnapshot() => _catalog.GetClips();

    public IReadOnlyList<PairedDeviceInfo> PairedDevices => _devices.List();

    public bool RevokeDevice(string deviceId) => _devices.Revoke(deviceId);

    public async Task<bool> ConfigureFirewallAsync()
    {
        if (!IsSharingRunning || _actualPort <= 0)
        {
            FirewallStatus = new(
                FirewallRuleState.Unavailable,
                "Start sharing before configuring Windows Firewall.",
                false);
            StateChanged?.Invoke();
            return false;
        }

        var executablePath = Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName;
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            FirewallStatus = new(
                FirewallRuleState.Unavailable,
                "The running ShadowPlay executable path could not be determined.",
                false);
            StateChanged?.Invoke();
            return false;
        }

        FirewallStatus = await _firewall.EnsurePrivateRuleAsync(executablePath, _actualPort).ConfigureAwait(false);
        _logger?.LogInformation(
            "Firewall setup for {ExecutablePath} TCP {Port}: {State}. {Detail}",
            executablePath,
            _actualPort,
            FirewallStatus.State,
            FirewallStatus.Detail);
        StateChanged?.Invoke();
        return FirewallStatus.State == FirewallRuleState.Ready;
    }

    public void OpenRecordingsFolderInExplorer()
    {
        var folder = RecordingsFolder;
        if (!string.IsNullOrWhiteSpace(folder) && Directory.Exists(folder))
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });
        }
    }

    private async Task StopCoreAsync()
    {
        if (_monitor is not null)
        {
            await _monitor.StopAsync().ConfigureAwait(false);
            await _monitor.DisposeAsync().ConfigureAwait(false);
            _monitor = null;
        }

        if (_apiApp is not null)
        {
            try
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                await _apiApp.StopAsync(timeout.Token).ConfigureAwait(false);
            }
            finally
            {
                await _apiApp.DisposeAsync().ConfigureAwait(false);
                _apiApp = null;
            }
        }
    }

    private static int? ResolvePort(WebApplication app)
    {
        var addresses = GetServerAddresses(app);

        foreach (var address in addresses)
        {
            if (Uri.TryCreate(address, UriKind.Absolute, out var uri) && uri.Port > 0)
            {
                return uri.Port;
            }
        }

        return null;
    }

    private static string[] GetServerAddresses(WebApplication app) =>
        app.Services.GetRequiredService<IServer>()
            .Features.Get<IServerAddressesFeature>()?.Addresses.ToArray()
            ?? [];

    private static string DescribeStartError(Exception ex) =>
        ex is SocketException
            ? "Could not bind the local network port. Try changing the port in settings."
            : "Sharing failed to start. See local logs for details.";

    private void SetStatus(ControllerStatus status)
    {
        Status = status;
        StateChanged?.Invoke();
    }

    public async ValueTask DisposeAsync() => await StopCoreAsync().ConfigureAwait(false);

    private sealed class StaticServerInfo(string serverId, string computerName) : IServerInfoProvider
    {
        public string ServerId { get; } = serverId;

        public string ComputerName { get; } = computerName;

        public DateTimeOffset StartedUtc { get; } = DateTimeOffset.UtcNow;
    }
}
