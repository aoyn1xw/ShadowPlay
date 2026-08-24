using System.Text;
using ShadowPlay.Core.Models;
using ShadowPlay.Core.Settings;

namespace ShadowPlay.Core.Devices;

/// <summary>
/// Registry of paired devices, persisted via <see cref="ISettingsStore"/>.
/// Token lookups use constant-time comparison against stored hashes.
/// </summary>
public sealed class DeviceRegistry : IDeviceRegistry
{
    private readonly ISettingsService _settings;
    private readonly TimeProvider _timeProvider;
    private readonly object _sync = new();

    public DeviceRegistry(ISettingsService settings, TimeProvider? timeProvider = null)
    {
        _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public PairedDeviceInfo Register(string deviceName, string tokenHash)
    {
        lock (_sync)
        {
            var device = new PairedDeviceInfo(
                Guid.NewGuid().ToString("N"),
                SanitizeName(deviceName),
                tokenHash,
                _timeProvider.GetUtcNow());

            _settings.Update(data => data.Devices.Add(device));
            return device;
        }
    }

    public PairedDeviceInfo? ValidateToken(string rawToken)
    {
        if (string.IsNullOrWhiteSpace(rawToken) || rawToken.Length > 512)
        {
            return null;
        }

        var hash = Pairing.Hashing.Sha256Hex(rawToken);
        lock (_sync)
        {
            foreach (var device in _settings.Current.Devices)
            {
                if (Pairing.Hashing.FixedTimeEqualsHex(device.TokenHash, hash))
                {
                    return device;
                }
            }
        }

        return null;
    }

    public bool Revoke(string deviceId)
    {
        lock (_sync)
        {
            var removed = false;
            _settings.Update(data =>
            {
                var count = data.Devices.RemoveAll(d => d.DeviceId == deviceId);
                removed = count > 0;
            });
            return removed;
        }
    }

    public IReadOnlyList<PairedDeviceInfo> List()
    {
        lock (_sync)
        {
            return _settings.Current.Devices.ToArray();
        }
    }

    private static string SanitizeName(string? name)
    {
        var builder = new StringBuilder();
        foreach (var ch in (name ?? string.Empty).Trim())
        {
            if (!char.IsControl(ch))
            {
                builder.Append(ch);
            }
        }

        var result = builder.ToString();
        if (result.Length == 0)
        {
            return "Unnamed device";
        }

        return result.Length <= 64 ? result : result[..64];
    }
}
