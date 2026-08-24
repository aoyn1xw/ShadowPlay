using ShadowPlay.Core.Models;

namespace ShadowPlay.Core.Pairing;

public enum PairingFailureKind
{
    InvalidCode,
    AlreadyUsed,
    Expired,
}

/// <summary>Outcome of a pair/exchange attempt.</summary>
public sealed record PairExchangeResult
{
    public bool Success { get; private init; }

    public PairingFailureKind? Failure { get; private init; }

    /// <summary>Raw bearer token. Present only on success and only ever returned once.</summary>
    public string? BearerToken { get; private init; }

    public Models.PairedDeviceInfo? Device { get; private init; }

    public static PairExchangeResult Failed(PairingFailureKind kind) => new() { Success = false, Failure = kind };

    public static PairExchangeResult Succeeded(string token, Models.PairedDeviceInfo device) =>
        new() { Success = true, BearerToken = token, Device = device };
}

/// <summary>An outstanding pairing offer rendered into the QR code.</summary>
public sealed record PairingOffer(string Code, DateTimeOffset CreatedAtUtc, DateTimeOffset ExpiresAtUtc)
{
    public bool IsExpired(DateTimeOffset now) => now >= ExpiresAtUtc;
}
