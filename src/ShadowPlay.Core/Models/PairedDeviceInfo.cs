namespace ShadowPlay.Core.Models;

/// <summary>A paired phone. Only the token hash is stored; raw tokens are shown once at pairing.</summary>
public sealed record PairedDeviceInfo(
    string DeviceId,
    string Name,
    string TokenHash,
    DateTimeOffset CreatedAtUtc);
