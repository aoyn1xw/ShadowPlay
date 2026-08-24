using ShadowPlay.Core.Models;

namespace ShadowPlay.Core.Devices;

public interface IDeviceRegistry
{
    /// <summary>Registers a device with an already-hashed bearer token.</summary>
    PairedDeviceInfo Register(string deviceName, string tokenHash);

    /// <summary>Validates a raw bearer token; returns the device or null.</summary>
    PairedDeviceInfo? ValidateToken(string rawToken);

    bool Revoke(string deviceId);

    IReadOnlyList<PairedDeviceInfo> List();
}
