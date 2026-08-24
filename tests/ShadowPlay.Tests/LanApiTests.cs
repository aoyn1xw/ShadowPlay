using Xunit;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.DependencyInjection;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.Time.Testing;
using ShadowPlay.Api;
using ShadowPlay.Core.Clips;
using ShadowPlay.Core.Devices;
using ShadowPlay.Core.Models;
using ShadowPlay.Core.Pairing;
using ShadowPlay.Core.Settings;

namespace ShadowPlay.Tests;

/// <summary>
/// End-to-end tests for the LAN API using a real Kestrel instance on port 0.
/// Covers auth, pairing exchange, listing, streaming downloads with ranges, and traversal safety.
/// </summary>
public sealed class LanApiTests : IAsyncLifetime, IDisposable
{
    private readonly TempFolder _folder = new();
    private readonly TempFolder _settingsFolder = new();
    private readonly FakeTimeProvider _time = new(new DateTimeOffset(2026, 5, 1, 0, 0, 0, TimeSpan.Zero));

    private ClipCatalog _catalog = null!;
    private PairingService _pairing = null!;
    private DeviceRegistry _devices = null!;
    private WebApplication _app = null!;
    private HttpClient _client = null!;
    private string _baseAddress = "";

    public async Task InitializeAsync()
    {
        var settings = new SettingsService(new JsonSettingsStore(_settingsFolder.Path));
        _catalog = new ClipCatalog();
        _devices = new DeviceRegistry(settings, _time);
        _pairing = new PairingService(new SecureTokenGenerator(), _devices, _time);

        var options = new LanApiOptions
        {
            Catalog = _catalog,
            Pairing = _pairing,
            Devices = _devices,
            ServerInfo = new StaticServerInfo("test-server-id", "TEST-PC"),
            Port = 0,
        };

        _app = LanApiFactory.Build(options);
        await _app.StartAsync();

        var addresses = _app.Services.GetRequiredService<IServer>()
            .Features.Get<IServerAddressesFeature>()!.Addresses;

        // Kestrel reports the wildcard bind (0.0.0.0); dial loopback instead.
        var boundPort = new Uri(addresses.First()).Port;
        _baseAddress = $"http://127.0.0.1:{boundPort}/";
        _client = new HttpClient { BaseAddress = new Uri(_baseAddress) };
    }

    public async Task DisposeAsync()
    {
        _client?.Dispose();
        if (_app is not null)
        {
            await _app.StopAsync();
            await _app.DisposeAsync();
        }
    }

    public void Dispose() => _folder.Dispose();

    // ---------------------------------------------------------------- helpers

    private async Task<(string Token, string DeviceId)> PairAsync(string deviceName = "Test iPhone")
    {
        var offer = _pairing.NewPairingOffer();
        var response = await _client.PostAsJsonAsync("/api/v1/pair/exchange",
            new { pairingCode = offer.Code, deviceName });
        response.EnsureSuccessStatusCode();

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return (body.GetProperty("token").GetString()!, body.GetProperty("deviceId").GetString()!);
    }

    private HttpClient AuthenticatedClient(string token) =>
        new() { BaseAddress = new Uri(_baseAddress), DefaultRequestHeaders = { Authorization = new("Bearer", token) } };

    private string AddClip(string name, int sizeBytes = 4096, int seed = 0, double lastWriteOffsetMinutes = -1)
    {
        var path = _folder.CreateMp4(name, sizeBytes);
        var bytes = new byte[sizeBytes];
        for (var i = 0; i < sizeBytes; i++)
        {
            bytes[i] = (byte)((i + seed) % 251);
        }
        File.WriteAllBytes(path, bytes);

        var lastWrite = DateTimeOffset.UtcNow.AddMinutes(lastWriteOffsetMinutes);
        File.SetLastWriteTimeUtc(path, lastWrite.UtcDateTime);

        var entry = new ClipEntry(
            ClipIdCalculator.Calculate(path),
            Path.GetFileName(path),
            path,
            sizeBytes,
            lastWrite);
        _catalog.AddOrUpdate(entry);
        return entry.Id;
    }

    // ------------------------------------------------------------------ tests

    [Fact]
    public async Task Health_is_available_without_authentication()
    {
        var response = await _client.GetAsync("/api/v1/health");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("ok", body.GetProperty("status").GetString());
        Assert.Equal("test-server-id", body.GetProperty("serverId").GetString());
        Assert.Equal(1, body.GetProperty("protocolVersion").GetInt32());
    }

    [Fact]
    public async Task Clips_endpoints_reject_requests_without_a_bearer_token()
    {
        foreach (var path in new[] { "/api/v1/clips", "/api/v1/server" })
        {
            var response = await _client.GetAsync(path);
            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
            Assert.Equal("Bearer", response.Headers.WwwAuthenticate.ToString());
        }
    }

    [Fact]
    public async Task Invalid_tokens_are_unauthorized()
    {
        using var client = AuthenticatedClient("totally-fake-token");
        var response = await client.GetAsync("/api/v1/clips");
        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
    }

    [Fact]
    public async Task Pair_exchange_issues_a_working_token()
    {
        var (token, deviceId) = await PairAsync();

        Assert.False(string.IsNullOrWhiteSpace(token));
        Assert.False(string.IsNullOrWhiteSpace(deviceId));

        using var client = AuthenticatedClient(token);
        var response = await client.GetAsync("/api/v1/server");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("test-server-id", body.GetProperty("serverId").GetString());
        Assert.Equal("TEST-PC", body.GetProperty("computerName").GetString());
    }

    [Fact]
    public async Task Pair_exchange_rejects_malformed_and_unknown_codes()
    {
        // Malformed body -> 400
        var badRequest = await _client.PostAsJsonAsync("/api/v1/pair/exchange", new { pairingCode = "", deviceName = "x" });
        Assert.Equal(HttpStatusCode.BadRequest, badRequest.StatusCode);

        // Unknown code -> 409
        _pairing.NewPairingOffer();
        var unknown = await _client.PostAsJsonAsync("/api/v1/pair/exchange", new { pairingCode = "0000-0000", deviceName = "x" });
        Assert.Equal(HttpStatusCode.Conflict, unknown.StatusCode);
    }

    [Fact]
    public async Task Pair_exchange_codes_are_single_use_and_expire()
    {
        var offer = _pairing.NewPairingOffer();

        var first = await _client.PostAsJsonAsync("/api/v1/pair/exchange",
            new { pairingCode = offer.Code, deviceName = "first" });
        Assert.Equal(HttpStatusCode.OK, first.StatusCode);

        var reused = await _client.PostAsJsonAsync("/api/v1/pair/exchange",
            new { pairingCode = offer.Code, deviceName = "second" });
        Assert.Equal(HttpStatusCode.Conflict, reused.StatusCode);

        var freshOffer = _pairing.NewPairingOffer();
        _time.Advance(TimeSpan.FromMinutes(11));
        var expired = await _client.PostAsJsonAsync("/api/v1/pair/exchange",
            new { pairingCode = freshOffer.Code, deviceName = "late" });
        Assert.Equal(HttpStatusCode.Conflict, expired.StatusCode);
    }

    [Fact]
    public async Task Revoked_device_loses_access_immediately()
    {
        var (token, deviceId) = await PairAsync();

        using (var client = AuthenticatedClient(token))
        {
            Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/api/v1/clips")).StatusCode);
        }

        Assert.True(_devices.Revoke(deviceId));

        using var afterRevoke = AuthenticatedClient(token);
        Assert.Equal(HttpStatusCode.Unauthorized, (await afterRevoke.GetAsync("/api/v1/clips")).StatusCode);
    }

    [Fact]
    public async Task Clips_are_listed_newest_first_without_paths()
    {
        var (token, _) = await PairAsync();

        var oldId = AddClip("old.mp4", lastWriteOffsetMinutes: -60);
        var newId = AddClip("new.mp4", lastWriteOffsetMinutes: -5);

        using var client = AuthenticatedClient(token);
        var response = await client.GetAsync("/api/v1/clips");
        response.EnsureSuccessStatusCode();

        var raw = await response.Content.ReadAsStringAsync();
        var clips = JsonDocument.Parse(raw).RootElement.EnumerateArray().ToList();

        Assert.Equal(2, clips.Count);
        Assert.Equal("new.mp4", clips[0].GetProperty("fileName").GetString());
        Assert.Equal(newId, clips[0].GetProperty("id").GetString());
        Assert.Equal("old.mp4", clips[1].GetProperty("fileName").GetString());

        // Privacy: no filesystem paths may leak through the API.
        Assert.DoesNotContain(_folder.Path, raw, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("fullPath", raw, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("path\"", raw, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Single_clip_lookup_returns_metadata_or_404()
    {
        var (token, _) = await PairAsync();
        var id = AddClip("lookup.mp4");

        using var client = AuthenticatedClient(token);

        var ok = await client.GetAsync($"/api/v1/clips/{id}");
        Assert.Equal(HttpStatusCode.OK, ok.StatusCode);
        var body = await ok.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(id, body.GetProperty("id").GetString());

        var missing = await client.GetAsync($"/api/v1/clips/{new string('A', 64)}");
        Assert.Equal(HttpStatusCode.NotFound, missing.StatusCode);
    }

    [Theory]
    [InlineData("../etc/passwd")]
    [InlineData("..%2f..%2fwindows%2fsystem32%2fconfig%2fsam")]
    [InlineData("short")]
    [InlineData("!!!!")]
    public async Task Non_id_clip_references_never_reach_the_filesystem(string bogusId)
    {
        var (token, _) = await PairAsync();
        using var client = AuthenticatedClient(token);

        var meta = await client.GetAsync($"/api/v1/clips/{bogusId}");
        var download = await client.GetAsync($"/api/v1/clips/{bogusId}/download");

        Assert.Equal(HttpStatusCode.NotFound, meta.StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, download.StatusCode);
        Assert.Null(download.Headers.Location);
    }

    [Fact]
    public async Task Download_streams_the_exact_original_bytes()
    {
        var (token, _) = await PairAsync();
        const int size = 64 * 1024 + 123;
        var id = AddClip("exact.mp4", size);
        var original = await File.ReadAllBytesAsync(Path.Combine(_folder.Path, "exact.mp4"));

        using var client = AuthenticatedClient(token);
        var response = await client.GetAsync($"/api/v1/clips/{id}/download");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("video/mp4", response.Content.Headers.ContentType!.MediaType);
        Assert.Contains("attachment", response.Content.Headers.ContentDisposition!.ToString(), StringComparison.Ordinal);
        Assert.Contains("exact.mp4", response.Content.Headers.ContentDisposition.ToString(), StringComparison.Ordinal);

        var bytes = await response.Content.ReadAsByteArrayAsync();
        Assert.Equal(size, bytes.Length);
        Assert.Equal(original, bytes); // byte-for-byte
    }

    [Fact]
    public async Task Download_supports_range_resumption()
    {
        var (token, _) = await PairAsync();
        var id = AddClip("range.mp4", sizeBytes: 1000, seed: 7);

        using var client = AuthenticatedClient(token);

        // First 100 bytes.
        using (var head = new HttpRequestMessage(HttpMethod.Get, $"/api/v1/clips/{id}/download"))
        {
            head.Headers.Range = new(0, 99);
            using var response = await client.SendAsync(head);
            Assert.Equal(HttpStatusCode.PartialContent, response.StatusCode);
            Assert.Equal("bytes 0-99/1000", response.Content.Headers.ContentRange!.ToString());
            var slice = await response.Content.ReadAsByteArrayAsync();
            Assert.Equal(100, slice.Length);
        }

        // Open-ended resume from byte 500.
        using (var tail = new HttpRequestMessage(HttpMethod.Get, $"/api/v1/clips/{id}/download"))
        {
            tail.Headers.Range = new(500, null);
            using var response = await client.SendAsync(tail);
            Assert.Equal(HttpStatusCode.PartialContent, response.StatusCode);
            Assert.Equal("bytes 500-999/1000", response.Content.Headers.ContentRange!.ToString());
            Assert.Equal(500, (await response.Content.ReadAsByteArrayAsync()).Length);
        }

        // Suffix range: final 100 bytes.
        using (var suffix = new HttpRequestMessage(HttpMethod.Get, $"/api/v1/clips/{id}/download"))
        {
            suffix.Headers.Range = new RangeHeaderValue(null, 100);
            using var response = await client.SendAsync(suffix);
            Assert.Equal(HttpStatusCode.PartialContent, response.StatusCode);
            Assert.Equal("bytes 900-999/1000", response.Content.Headers.ContentRange!.ToString());
        }

        // Unsatisfiable range.
        using (var invalid = new HttpRequestMessage(HttpMethod.Get, $"/api/v1/clips/{id}/download"))
        {
            invalid.Headers.Range = new(5000, null);
            using var response = await client.SendAsync(invalid);
            Assert.Equal(HttpStatusCode.RequestedRangeNotSatisfiable, response.StatusCode);
        }
    }

    [Fact]
    public async Task Download_of_vanished_clip_returns_404()
    {
        var (token, _) = await PairAsync();
        var id = AddClip("vanishing.mp4");
        File.Delete(Path.Combine(_folder.Path, "vanishing.mp4"));

        using var client = AuthenticatedClient(token);
        var response = await client.GetAsync($"/api/v1/clips/{id}/download");
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Fact]
    public async Task Non_api_routes_return_not_found()
    {
        var response = await _client.GetAsync("/");
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    private sealed class StaticServerInfo(string serverId, string computerName) : IServerInfoProvider
    {
        public string ServerId { get; } = serverId;

        public string ComputerName { get; } = computerName;

        public DateTimeOffset StartedUtc { get; } = DateTimeOffset.UtcNow;
    }
}
