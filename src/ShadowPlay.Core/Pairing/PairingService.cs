using Microsoft.Extensions.Logging;
using ShadowPlay.Core.Devices;

namespace ShadowPlay.Core.Pairing;

public interface IPairingService
{
    /// <summary>Creates a fresh one-time pairing code, invalidating any previous offer.</summary>
    PairingOffer NewPairingOffer();

    /// <summary>The current offer, if it has not expired or been consumed.</summary>
    PairingOffer? CurrentOffer { get; }

    /// <summary>
    /// Exchanges a pairing code for a long-lived bearer token.
    /// Codes are single-use and expire after ten minutes. Raw codes/tokens are never logged.
    /// </summary>
    PairExchangeResult Exchange(string? pairingCode, string? deviceName);
}

public sealed class PairingService : IPairingService
{
    public static readonly TimeSpan CodeLifetime = TimeSpan.FromMinutes(10);

    private readonly ISecretGenerator _secrets;
    private readonly IDeviceRegistry _devices;
    private readonly TimeProvider _timeProvider;
    private readonly ILogger? _logger;
    private readonly object _sync = new();
    private (string Code, DateTimeOffset CreatedUtc, DateTimeOffset ExpiresUtc, bool Used)? _active;

    public PairingService(
        ISecretGenerator secrets,
        IDeviceRegistry devices,
        TimeProvider? timeProvider = null,
        ILogger? logger = null)
    {
        _secrets = secrets ?? throw new ArgumentNullException(nameof(secrets));
        _devices = devices ?? throw new ArgumentNullException(nameof(devices));
        _timeProvider = timeProvider ?? TimeProvider.System;
        _logger = logger;
    }

    public PairingOffer? CurrentOffer
    {
        get
        {
            lock (_sync)
            {
                var active = _active;
                if (active is null || active.Value.Used || _timeProvider.GetUtcNow() >= active.Value.ExpiresUtc)
                {
                    return null;
                }

                return new PairingOffer(active.Value.Code, active.Value.CreatedUtc, active.Value.ExpiresUtc);
            }
        }
    }

    public PairingOffer NewPairingOffer()
    {
        lock (_sync)
        {
            var now = _timeProvider.GetUtcNow();
            var code = _secrets.CreatePairingCode();
            _active = (code, now, now + CodeLifetime, Used: false);
            _logger?.LogInformation("New pairing code generated (valid for {Minutes} minutes)", CodeLifetime.TotalMinutes);
            return new PairingOffer(code, now, now + CodeLifetime);
        }
    }

    public PairExchangeResult Exchange(string? pairingCode, string? deviceName)
    {
        var normalized = NormalizeCode(pairingCode);
        if (normalized.Length == 0)
        {
            return PairExchangeResult.Failed(PairingFailureKind.InvalidCode);
        }

        lock (_sync)
        {
            var active = _active;
            if (active is null || !string.Equals(NormalizeCode(active.Value.Code), normalized, StringComparison.Ordinal))
            {
                _logger?.LogInformation("Pairing rejected: unknown code");
                return PairExchangeResult.Failed(PairingFailureKind.InvalidCode);
            }

            var (code, createdUtc, expiresUtc, used) = active.Value;

            if (used)
            {
                _logger?.LogInformation("Pairing rejected: code already used");
                return PairExchangeResult.Failed(PairingFailureKind.AlreadyUsed);
            }

            if (_timeProvider.GetUtcNow() >= expiresUtc)
            {
                _logger?.LogInformation("Pairing rejected: code expired");
                return PairExchangeResult.Failed(PairingFailureKind.Expired);
            }

            // Consume the code before issuing anything.
            _active = (code, createdUtc, expiresUtc, Used: true);

            var rawToken = _secrets.CreateBearerToken();
            var hash = Hashing.Sha256Hex(rawToken);
            var device = _devices.Register(deviceName ?? "Unnamed device", hash);

            _logger?.LogInformation("Device paired successfully");
            return PairExchangeResult.Succeeded(rawToken, device);
        }
    }

    private static string NormalizeCode(string? input)
    {
        if (string.IsNullOrWhiteSpace(input))
        {
            return string.Empty;
        }

        var builder = new System.Text.StringBuilder(input.Length);
        foreach (var ch in input.Trim().ToUpperInvariant())
        {
            switch (ch)
            {
                case ' ' or '-' or '\t':
                    continue;
                case 'I' or 'L':
                    builder.Append('1');
                    break;
                case 'O':
                    builder.Append('0');
                    break;
                case 'U':
                    builder.Append('V');
                    break;
                default:
                    builder.Append(ch);
                    break;
            }
        }

        return builder.ToString();
    }
}
