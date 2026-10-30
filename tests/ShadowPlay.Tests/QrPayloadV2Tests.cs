using System.Security.Cryptography;
using System.Text.Json;
using ShadowPlay.Core.Networking;
using Xunit;

namespace ShadowPlay.Tests;

/// <summary>
/// Serialization contract tests for the pairing QR payload (protocol v2 with
/// pinned-TLS fields). Phones decode this JSON, so key names, protocol
/// version handling and the HTTP-only fallback shapes must stay stable.
/// </summary>
public sealed class QrPayloadV2Tests
{
    private const string Fingerprint =
        "A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8091728394A5B6C7D8E9F0A1B2C3D4";

    private static QrPayload SamplePayload() => new()
    {
        ServerId = "srv-1",
        ComputerName = "GAMING PC",
        LanAddress = "192.168.1.20",
        Port = 5177,
        PairingCode = "1234-5678",
        HttpsPort = 5178,
        CertSha256 = Fingerprint,
    };

    [Fact]
    public void Current_protocol_version_is_2()
    {
        Assert.Equal(2, QrPayload.CurrentProtocolVersion);
        Assert.Equal(2, new QrPayload().ProtocolVersion);
    }

    [Fact]
    public void Payload_serializes_with_the_documented_camel_case_keys()
    {
        var document = JsonDocument.Parse(SamplePayload().ToJson()).RootElement;

        Assert.Equal(2, document.GetProperty("v").GetInt32());
        Assert.Equal("srv-1", document.GetProperty("serverId").GetString());
        Assert.Equal("GAMING PC", document.GetProperty("computerName").GetString());
        Assert.Equal("192.168.1.20", document.GetProperty("lanAddress").GetString());
        Assert.Equal(5177, document.GetProperty("port").GetInt32());
        Assert.Equal("1234-5678", document.GetProperty("pairingCode").GetString());
        Assert.Equal(5178, document.GetProperty("httpsPort").GetInt32());
        Assert.Equal(Fingerprint, document.GetProperty("certSha256").GetString());
    }

    [Fact]
    public void Tls_fields_round_trip_through_deserialization()
    {
        var json = SamplePayload().ToJson();
        var parsed = JsonSerializer.Deserialize<QrPayload>(json);

        Assert.NotNull(parsed);
        Assert.Equal(2, parsed!.ProtocolVersion);
        Assert.Equal(5178, parsed.HttpsPort);
        // Fingerprint casing must survive untouched; mobile devices normalize
        // the value themselves before comparing pins.
        Assert.Equal(Fingerprint, parsed.CertSha256);
    }

    [Fact]
    public void V1_payload_without_tls_fields_deserializes_as_http_only()
    {
        // Payloads produced by servers from protocol v1 carry neither key.
        const string v1Json = """
            {"v":1,"serverId":"srv-1","computerName":"GAMING PC",
             "lanAddress":"192.168.1.20","port":5177,"pairingCode":"1234-5678"}
            """;

        var parsed = JsonSerializer.Deserialize<QrPayload>(v1Json);

        Assert.NotNull(parsed);
        Assert.Equal(1, parsed!.ProtocolVersion);
        Assert.Null(parsed.HttpsPort);
        Assert.Null(parsed.CertSha256);
    }

    [Fact]
    public void Explicit_null_tls_fields_deserialize_as_absent()
    {
        // HTTP-only servers serialize null TLS fields; the phone decoder must
        // treat JSON null exactly like a missing key.
        var payload = new QrPayload
        {
            ServerId = "srv-1",
            ComputerName = "GAMING PC",
            LanAddress = "192.168.1.20",
            Port = 5177,
            PairingCode = "1234-5678",
            HttpsPort = null,
            CertSha256 = null,
        };

        var json = payload.ToJson();
        var document = JsonDocument.Parse(json).RootElement;
        Assert.Equal(JsonValueKind.Null, document.GetProperty("httpsPort").ValueKind);
        Assert.Equal(JsonValueKind.Null, document.GetProperty("certSha256").ValueKind);

        var parsed = JsonSerializer.Deserialize<QrPayload>(json);
        Assert.NotNull(parsed);
        Assert.Null(parsed!.HttpsPort);
        Assert.Null(parsed.CertSha256);
    }

    [Fact]
    public void A_real_certificate_fingerprint_is_64_uppercase_hex_characters()
    {
        using var certificate = HttpsIdentityService.CreateCertificate(
            [System.Net.IPAddress.Loopback],
            DateTimeOffset.UtcNow.AddMinutes(-1));
        var fingerprint = certificate.GetCertHashString(HashAlgorithmName.SHA256);

        Assert.Matches("^[0-9A-F]{64}$", fingerprint);
    }
}
