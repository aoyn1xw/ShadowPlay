using ShadowPlay.Core.Clips;
using ShadowPlay.Core.Devices;

namespace ShadowPlay.Api;

/// <summary>Static server identity surfaced through the API.</summary>
public interface IServerInfoProvider
{
    string ServerId { get; }

    string ComputerName { get; }

    DateTimeOffset StartedUtc { get; }
}

/// <summary>
/// Everything the LAN API needs. The desktop app supplies real implementations;
/// tests supply fakes. Keeping this explicit makes swapping in pinned HTTPS later a local change.
/// </summary>
public sealed class LanApiOptions
{
    public required IClipCatalog Catalog { get; init; }

    public required Core.Pairing.IPairingService Pairing { get; init; }

    public required IDeviceRegistry Devices { get; init; }

    public required IServerInfoProvider ServerInfo { get; init; }

    /// <summary>Optional desktop-side duration and thumbnail provider.</summary>
    public IClipPreviewProvider? ClipPreview { get; init; }

    /// <summary>Product version reported to compatible clients.</summary>
    public string ServerVersion { get; init; } = "0.1.0";

    public const int ApiVersion = 1;

    /// <summary>TCP port to bind. 0 lets the OS pick a free port (used by tests/smoke).</summary>
    public int Port { get; init; } = Core.Models.AppSettingsData.DefaultPort;

    /// <summary>Reject clients whose address is not loopback/private.</summary>
    public bool RestrictToPrivateNetworks { get; init; } = true;

    /// <summary>Optional hook for tests or alternate transports.</summary>
    public Action<Microsoft.AspNetCore.Hosting.IWebHostBuilder>? ConfigureWebHost { get; init; }

    /// <summary>
    /// Self-signed listener certificate for pinned LAN HTTPS. Null starts
    /// HTTP-only (legacy behaviour); when present, Kestrel additionally
    /// listens on <see cref="HttpsPort"/> over TLS. Clients pin the leaf
    /// certificate's SHA-256 fingerprint, which is distributed through the
    /// pairing QR code and server DTO.
    /// </summary>
    public System.Security.Cryptography.X509Certificates.X509Certificate2? HttpsCertificate { get; init; }

    /// <summary>TCP port for the TLS listener. 0 lets the OS pick a free port.</summary>
    public int HttpsPort { get; init; }

    /// <summary>Fresh bearer tokens are only ever returned here, once per pairing.</summary>
    public static readonly string ApiTitle = "ShadowPlay LAN API";

    public IReadOnlyList<string> Capabilities
    {
        get
        {
            var capabilities = new List<string> { "clips.rangePlayback" };
            if (ClipPreview is not null)
            {
                capabilities.Add("clips.duration");
            }

            if (ClipPreview?.SupportsThumbnails == true)
            {
                capabilities.Add("clips.thumbnails");
            }

            return capabilities;
        }
    }
}
