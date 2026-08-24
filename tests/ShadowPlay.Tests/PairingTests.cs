using Xunit;
using Microsoft.Extensions.Time.Testing;
using ShadowPlay.Core.Devices;
using ShadowPlay.Core.Models;
using ShadowPlay.Core.Pairing;
using ShadowPlay.Core.Settings;

namespace ShadowPlay.Tests;

/// <summary>Shared fixture wiring: settings in a temp dir + registry + pairing service.</summary>
public sealed class PairingHarness : IDisposable
{
    public TempFolder Folder { get; } = new();
    public FakeTimeProvider Time { get; } = new(new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero));
    public SettingsService Settings { get; }
    public DeviceRegistry Devices { get; }
    public PairingService Pairing { get; }

    public PairingHarness()
    {
        Settings = new SettingsService(new JsonSettingsStore(Folder.Path));
        Devices = new DeviceRegistry(Settings, Time);
        Pairing = new PairingService(new SecureTokenGenerator(), Devices, Time);
    }

    public void Dispose() => Folder.Dispose();
}

public class PairingCodeTests : IDisposable
{
    private readonly PairingHarness _harness = new();

    [Fact]
    public void Generated_code_has_expected_format()
    {
        var offer = _harness.Pairing.NewPairingOffer();

        Assert.Matches("^[0-9A-Z]{4}-[0-9A-Z]{4}$", offer.Code);
        Assert.Equal(offer.ExpiresAtUtc - offer.CreatedAtUtc, PairingService.CodeLifetime);
        Assert.Equal(TimeSpan.FromMinutes(10), PairingService.CodeLifetime);
    }

    [Fact]
    public void Regenerating_invalidates_the_previous_code()
    {
        var first = _harness.Pairing.NewPairingOffer();
        var second = _harness.Pairing.NewPairingOffer();

        var result = _harness.Pairing.Exchange(first.Code, "phone");

        Assert.False(result.Success);
        Assert.Equal(PairingFailureKind.InvalidCode, result.Failure);

        Assert.True(_harness.Pairing.Exchange(second.Code, "phone").Success);
    }

    [Fact]
    public void Unknown_code_fails_without_registering_a_device()
    {
        _harness.Pairing.NewPairingOffer();

        var result = _harness.Pairing.Exchange("ZZZZ-ZZZZ", "phone");

        Assert.Equal(PairingFailureKind.InvalidCode, result.Failure);
        Assert.Empty(_harness.Devices.List());
    }

    [Fact]
    public void Code_expires_after_ten_minutes()
    {
        var offer = _harness.Pairing.NewPairingOffer();
        _harness.Time.Advance(TimeSpan.FromMinutes(10) + TimeSpan.FromSeconds(1));

        var result = _harness.Pairing.Exchange(offer.Code, "late phone");

        Assert.False(result.Success);
        Assert.Equal(PairingFailureKind.Expired, result.Failure);
        Assert.Empty(_harness.Devices.List());
    }

    [Fact]
    public void Code_is_single_use()
    {
        var offer = _harness.Pairing.NewPairingOffer();

        var first = _harness.Pairing.Exchange(offer.Code, "first phone");
        var second = _harness.Pairing.Exchange(offer.Code, "second phone");

        Assert.True(first.Success);
        Assert.False(second.Success);
        Assert.Equal(PairingFailureKind.AlreadyUsed, second.Failure);
        Assert.Single(_harness.Devices.List());
    }

    [Fact]
    public void Current_offer_disappears_when_expired_or_used()
    {
        var offer = _harness.Pairing.NewPairingOffer();
        Assert.NotNull(_harness.Pairing.CurrentOffer);

        _harness.Pairing.Exchange(offer.Code, "phone");
        Assert.Null(_harness.Pairing.CurrentOffer);

        var next = _harness.Pairing.NewPairingOffer();
        _harness.Time.Advance(TimeSpan.FromMinutes(11));
        Assert.Null(_harness.Pairing.CurrentOffer);
    }

    [Fact]
    public void Code_normalization_accepts_lowercase_and_separators()
    {
        var offer = _harness.Pairing.NewPairingOffer();
        var sloppy = offer.Code.ToLowerInvariant().Replace("-", " ");

        Assert.True(_harness.Pairing.Exchange(sloppy, "phone").Success);
    }

    public void Dispose() => _harness.Dispose();
}

public class BearerTokenTests : IDisposable
{
    private readonly PairingHarness _harness = new();

    [Fact]
    public void Exchange_returns_token_once_and_stores_only_its_hash()
    {
        var offer = _harness.Pairing.NewPairingOffer();
        var result = _harness.Pairing.Exchange(offer.Code, "iPhone 15");

        Assert.True(result.Success);
        var token = result.BearerToken!;
        Assert.False(string.IsNullOrEmpty(token));

        var stored = Assert.Single(_harness.Devices.List());
        Assert.NotEqual(token, stored.TokenHash); // raw token never persisted
        Assert.Matches("^[0-9A-F]{64}$", stored.TokenHash); // it's a SHA-256 hex hash
        Assert.Equal("iPhone 15", stored.Name);
        Assert.Equal(_harness.Time.GetUtcNow(), stored.CreatedAtUtc);
    }

    [Fact]
    public void Valid_tokens_validate_against_the_hash()
    {
        var offer = _harness.Pairing.NewPairingOffer();
        var result = _harness.Pairing.Exchange(offer.Code, "device");
        var token = result.BearerToken!;

        var device = _harness.Devices.ValidateToken(token);
        Assert.NotNull(device);
        Assert.Equal(result.Device!.DeviceId, device.DeviceId);
    }

    [Fact]
    public void Garbage_tokens_are_rejected()
    {
        var offer = _harness.Pairing.NewPairingOffer();
        _harness.Pairing.Exchange(offer.Code, "device");

        Assert.Null(_harness.Devices.ValidateToken("not-a-token"));
        Assert.Null(_harness.Devices.ValidateToken(""));
        Assert.Null(_harness.Devices.ValidateToken(new string('x', 40)));
    }

    [Fact]
    public void Revoked_devices_can_no_longer_validate()
    {
        var offer = _harness.Pairing.NewPairingOffer();
        var result = _harness.Pairing.Exchange(offer.Code, "doomed device");
        var deviceId = result.Device!.DeviceId;
        var token = result.BearerToken!;

        Assert.NotNull(_harness.Devices.ValidateToken(token));

        Assert.True(_harness.Devices.Revoke(deviceId));

        // Registry is backed by live settings; revalidation must fail now.
        Assert.Null(_harness.Devices.ValidateToken(token));
        Assert.Empty(_harness.Devices.List());
    }

    [Fact]
    public void Tokens_survive_restart_through_persistence()
    {
        var storePath = System.IO.Path.Combine(_harness.Folder.Path, "settings.json");

        string token;
        var offer = _harness.Pairing.NewPairingOffer();
        var result = _harness.Pairing.Exchange(offer.Code, "persistent device");
        token = result.BearerToken!;

        // Simulate an app restart with a brand-new object graph over the same folder.
        var freshSettings = new SettingsService(new JsonSettingsStore(_harness.Folder.Path));
        var freshRegistry = new DeviceRegistry(freshSettings, _harness.Time);

        var device = freshRegistry.ValidateToken(token);
        Assert.NotNull(device);
        Assert.Equal("persistent device", device.Name);
    }

    public void Dispose() => _harness.Dispose();
}
