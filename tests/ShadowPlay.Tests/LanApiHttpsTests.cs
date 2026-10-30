using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Time.Testing;
using ShadowPlay.Api;
using ShadowPlay.Core.Clips;
using ShadowPlay.Core.Devices;
using ShadowPlay.Core.Networking;
using ShadowPlay.Core.Pairing;
using ShadowPlay.Core.Settings;
using Xunit;

namespace ShadowPlay.Tests;

/// <summary>
/// End-to-end tests for pinned HTTPS: a real Kestrel instance with a plain and
/// a TLS listener bound side by side, using a real self-signed ECDSA P-256
/// identity. Phones pair once and must pin the leaf certificate's SHA-256
/// fingerprint for every later exchange; a TLS-capable client never downgrades
/// to HTTP.
/// </summary>
public sealed class LanApiHttpsTests : IAsyncLifetime, IDisposable
{
    private readonly TempFolder _folder = new();
    private readonly TempFolder _settingsFolder = new();
    private readonly FakeTimeProvider _time = new(new DateTimeOffset(2026, 5, 1, 0, 0, 0, TimeSpan.Zero));

    private static readonly Regex HexFingerprint = new("^[0-9A-F]{64}$", RegexOptions.Compiled);

    private ClipCatalog _catalog = null!;
    private PairingService _pairing = null!;
    private DeviceRegistry _devices = null!;
    private WebApplication _app = null!;
    private HttpClient _http = null!;
    private string _httpBase = "";
    private string _httpsBase = "";
    private int _httpsPort;
    private X509Certificate2 _identityCertificate = null!;
    private string _thumbprint = null!;

    public async Task InitializeAsync()
    {
        var settings = new SettingsService(new JsonSettingsStore(_settingsFolder.Path));
        _catalog = new ClipCatalog();
        _devices = new DeviceRegistry(settings, _time);
        _pairing = new PairingService(new SecureTokenGenerator(), _devices, _time);

        _identityCertificate = HttpsIdentityService.CreateCertificate(
            [IPAddress.Loopback],
            DateTimeOffset.UtcNow.AddMinutes(-1));
        _thumbprint = _identityCertificate.GetCertHashString(HashAlgorithmName.SHA256);
        _httpsPort = ReserveFreePort();

        var options = new LanApiOptions
        {
            Catalog = _catalog,
            Pairing = _pairing,
            Devices = _devices,
            ServerInfo = new StaticServerInfo("test-server-id", "TEST-PC"),
            ServerVersion = "test-server-version",
            Port = 0,
            HttpsPort = _httpsPort,
            HttpsCertificate = _identityCertificate,
        };

        _app = LanApiFactory.Build(options);
        await _app.StartAsync();

        var addresses = _app.Services.GetRequiredService<IServer>()
            .Features.Get<IServerAddressesFeature>()!.Addresses;

        // Kestrel reports the wildcard binds (0.0.0.0); dial loopback instead.
        var boundHttps = new Uri(addresses.Single(item => new Uri(item).Scheme == "https")).Port;
        var boundHttp = new Uri(addresses.Single(item => new Uri(item).Scheme == "http")).Port;
        Assert.Equal(_httpsPort, boundHttps);
        Assert.NotEqual(_httpsPort, boundHttp);

        _httpBase = $"http://127.0.0.1:{boundHttp}/";
        _httpsBase = $"https://127.0.0.1:{boundHttps}/";
        _http = new HttpClient { BaseAddress = new Uri(_httpBase) };
    }

    public async Task DisposeAsync()
    {
        _http?.Dispose();
        if (_app is not null)
        {
            await _app.StopAsync();
            await _app.DisposeAsync();
        }

        _identityCertificate?.Dispose();
    }

    public void Dispose()
    {
        _folder.Dispose();
        _settingsFolder.Dispose();
    }

    // ---------------------------------------------------------------- helpers

    private static int ReserveFreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            return ((IPEndPoint)listener.LocalEndpoint).Port;
        }
        finally
        {
            listener.Stop();
        }
    }

    /// <summary>Exchanges the pairing code on the plain listener; bearer tokens are valid on both transports.</summary>
    private async Task<string> PairAsync(string deviceName = "Test iPhone")
    {
        var offer = _pairing.NewPairingOffer();
        var response = await _http.PostAsJsonAsync(
            "/api/v1/pair/exchange",
            new { pairingCode = offer.Code, deviceName });
        response.EnsureSuccessStatusCode();

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        return body.GetProperty("token").GetString()!;
    }

    /// <summary>An HTTP client that only accepts a server certificate with the given SHA-256 fingerprint.</summary>
    private HttpClient HttpsClientPinnedTo(string thumbprint)
    {
        var handler = new HttpClientHandler
        {
            ServerCertificateCustomValidationCallback =
                (_, certificate, _, _) =>
                    certificate is not null && string.Equals(
                        certificate.GetCertHashString(HashAlgorithmName.SHA256),
                        thumbprint,
                        StringComparison.OrdinalIgnoreCase),
        };
        return new HttpClient(handler) { BaseAddress = new Uri(_httpsBase) };
    }

    private static int HttpPortOf(WebApplication app)
    {
        var addresses = app.Services.GetRequiredService<IServer>()
            .Features.Get<IServerAddressesFeature>()!.Addresses;
        var address = addresses.Single(item => new Uri(item).Scheme == "http");
        return new Uri(address).Port;
    }

    private sealed record StaticServerInfo(string ServerId, string ComputerName)
        : IServerInfoProvider
    {
        public DateTimeOffset StartedUtc { get; } = DateTimeOffset.UtcNow;
    }

    // ------------------------------------------------------------------ tests

    [Fact]
    public async Task Health_is_served_over_pinned_https_without_authentication()
    {
        using var client = HttpsClientPinnedTo(_thumbprint);
        var response = await client.GetAsync("/api/v1/health");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("ok", body.GetProperty("status").GetString());
        Assert.Equal("test-server-id", body.GetProperty("serverId").GetString());
    }

    [Fact]
    public async Task Paired_tokens_are_valid_on_the_tls_transport()
    {
        var token = await PairAsync();

        using var client = HttpsClientPinnedTo(_thumbprint);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await client.GetAsync("/api/v1/server");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("test-server-id", body.GetProperty("serverId").GetString());
        Assert.Equal("TEST-PC", body.GetProperty("computerName").GetString());
    }

    [Fact]
    public async Task Https_listener_rejects_missing_and_invalid_tokens()
    {
        using var client = HttpsClientPinnedTo(_thumbprint);

        var anonymous = await client.GetAsync("/api/v1/server");
        Assert.Equal(HttpStatusCode.Unauthorized, anonymous.StatusCode);

        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "totally-fake-token");
        var wrongToken = await client.GetAsync("/api/v1/server");
        Assert.Equal(HttpStatusCode.Unauthorized, wrongToken.StatusCode);
        Assert.Equal("Bearer", wrongToken.Headers.WwwAuthenticate.ToString());
    }

    [Fact]
    public async Task Pin_mismatch_fails_before_any_http_processing()
    {
        // A phone that pinned a different (stale or foreign) certificate must
        // abort during the TLS handshake: the connection never reaches any
        // endpoint or authentication middleware.
        using var decoy = HttpsIdentityService.CreateCertificate(
            [IPAddress.Loopback],
            DateTimeOffset.UtcNow.AddMinutes(-1));
        var decoyThumbprint = decoy.GetCertHashString(HashAlgorithmName.SHA256);

        using var client = HttpsClientPinnedTo(decoyThumbprint);
        await Assert.ThrowsAnyAsync<Exception>(() => client.GetAsync("/api/v1/health"));
    }

    [Fact]
    public async Task Plain_http_keeps_serving_alongside_https()
    {
        var token = await PairAsync();

        var health = await _http.GetAsync("/api/v1/health");
        Assert.Equal(HttpStatusCode.OK, health.StatusCode);
        var healthBody = await health.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal("ok", healthBody.GetProperty("status").GetString());

        using var client = new HttpClient
        {
            BaseAddress = new Uri(_httpBase),
            DefaultRequestHeaders = { Authorization = new AuthenticationHeaderValue("Bearer", token) },
        };
        var serverInfo = await client.GetAsync("/api/v1/server");
        Assert.Equal(HttpStatusCode.OK, serverInfo.StatusCode);
    }

    [Fact]
    public async Task Server_dto_advertises_the_https_port_and_certificate_fingerprint()
    {
        var token = await PairAsync();

        using var client = HttpsClientPinnedTo(_thumbprint);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var response = await client.GetAsync("/api/v1/server");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        var body = await response.Content.ReadFromJsonAsync<JsonElement>();
        Assert.Equal(_httpsPort, body.GetProperty("httpsPort").GetInt32());
        Assert.Equal(_thumbprint, body.GetProperty("httpsCertSha256").GetString(), ignoreCase: true);
        Assert.Matches(HexFingerprint, body.GetProperty("httpsCertSha256").GetString()!);
    }

    [Fact]
    public async Task Server_dto_omits_https_advertising_without_a_certificate()
    {
        // HTTP-only servers (legacy behaviour: phones paired before pinned
        // TLS) must not advertise TLS at all, so clients never expect a pin.
        await using var legacyApp = LanApiFactory.Build(new LanApiOptions
        {
            Catalog = _catalog,
            Pairing = _pairing,
            Devices = _devices,
            ServerInfo = new StaticServerInfo("test-server-id", "TEST-PC"),
            ServerVersion = "test-server-version",
            Port = 0,
        });
        await legacyApp.StartAsync();

        var addresses = legacyApp.Services.GetRequiredService<IServer>()
            .Features.Get<IServerAddressesFeature>()!.Addresses;
        Assert.Single(addresses);

        var baseAddress = $"http://127.0.0.1:{HttpPortOf(legacyApp)}/";
        var client = new HttpClient { BaseAddress = new Uri(baseAddress) };

        var offer = _pairing.NewPairingOffer();
        var exchange = await client.PostAsJsonAsync(
            "/api/v1/pair/exchange",
            new { pairingCode = offer.Code, deviceName = "Legacy iPhone" });
        exchange.EnsureSuccessStatusCode();

        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer", (await exchange.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("token").GetString()!);
        var serverInfo = await client.GetAsync("/api/v1/server");
        Assert.Equal(HttpStatusCode.OK, serverInfo.StatusCode);

        var raw = await serverInfo.Content.ReadAsStringAsync();
        Assert.DoesNotContain("\"httpsPort\"", raw, StringComparison.Ordinal);
        Assert.DoesNotContain("\"httpsCertSha256\"", raw, StringComparison.Ordinal);
        client.Dispose();
    }
}
