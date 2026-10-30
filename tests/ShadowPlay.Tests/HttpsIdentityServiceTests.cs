using System.Net;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;
using ShadowPlay.Core.Networking;
using Xunit;

namespace ShadowPlay.Tests;

/// <summary>
/// Unit tests for the pinned-TLS certificate identity used by the LAN HTTPS
/// listener. <see cref="HttpsIdentityService.GetOrCreateIdentity"/> is
/// intentionally not covered here: it reads the real
/// <c>CurrentUser\My</c> certificate store and must never be touched by CI.
/// </summary>
public sealed class HttpsIdentityServiceTests
{
    private static readonly IPAddress LanAddress = IPAddress.Parse("192.168.10.42");
    private static readonly IPAddress OtherLanAddress = IPAddress.Parse("192.168.10.43");
    private static readonly DateTimeOffset NotBefore = new(2026, 5, 1, 0, 0, 0, TimeSpan.Zero);

    private static readonly Regex HexFingerprint = new("^[0-9A-F]{64}$", RegexOptions.Compiled);

    [Fact]
    public void Certificates_use_the_documented_subject_and_carry_a_private_key()
    {
        using var certificate = HttpsIdentityService.CreateCertificate(
            [LanAddress], NotBefore);

        Assert.StartsWith("CN=ShadowPlay Local", certificate.Subject, StringComparison.Ordinal);
        Assert.True(certificate.HasPrivateKey);
        Assert.Matches(HexFingerprint, certificate.GetCertHashString(HashAlgorithmName.SHA256));
    }

    [Fact]
    public void Certificate_lifetime_follows_the_requested_window()
    {
        using var defaultLifetime = HttpsIdentityService.CreateCertificate(
            [LanAddress], NotBefore);
        Assert.InRange(
            defaultLifetime.NotAfter - defaultLifetime.NotBefore,
            TimeSpan.FromDays(3649),
            TimeSpan.FromDays(3651));

        using var customLifetime = HttpsIdentityService.CreateCertificate(
            [LanAddress], NotBefore, lifetime: TimeSpan.FromDays(30));
        Assert.InRange(
            customLifetime.NotAfter - customLifetime.NotBefore,
            TimeSpan.FromDays(29),
            TimeSpan.FromDays(31));
    }

    [Fact]
    public void Subject_alternative_names_cover_request_dns_host_and_all_addresses()
    {
        using var certificate = HttpsIdentityService.CreateCertificate(
            [LanAddress, OtherLanAddress], NotBefore, dnsName: "gaming-pc.lan");

        var san = certificate.Extensions.OfType<X509Extension>()
            .Single(extension => extension.Oid?.Value == "2.5.29.17");
        var parsed = HttpsIdentityService.TryParseSubjectAlternativeNames(
            san.RawData, out var dnsNames, out var addresses);

        Assert.True(parsed);
        Assert.Contains("gaming-pc.lan", dnsNames);
        // Every requested address is present, plus loopback for smoke checks.
        Assert.Contains(LanAddress, addresses);
        Assert.Contains(OtherLanAddress, addresses);
        Assert.Contains(IPAddress.Loopback, addresses);
    }

    [Fact]
    public void Address_coverage_requires_every_requested_value()
    {
        using var certificate = HttpsIdentityService.CreateCertificate(
            [LanAddress], NotBefore);

        Assert.True(HttpsIdentityService.CoversAddresses(certificate, [LanAddress]));
        Assert.True(HttpsIdentityService.CoversAddresses(certificate, [LanAddress, IPAddress.Loopback]));
        Assert.True(HttpsIdentityService.CoversAddresses(certificate, []));
        Assert.False(HttpsIdentityService.CoversAddresses(certificate, [OtherLanAddress]));
        Assert.False(HttpsIdentityService.CoversAddresses(
            certificate, [LanAddress, OtherLanAddress]));
    }

    [Fact]
    public void Address_coverage_normalizes_mapped_ipv6_notation()
    {
        var mapped = LanAddress.MapToIPv6();
        Assert.True(mapped.IsIPv4MappedToIPv6);

        var normalized = HttpsIdentityService.NormalizeLanAddresses(
            [LanAddress, mapped]);
        var single = Assert.Single(normalized);
        Assert.Equal(System.Net.Sockets.AddressFamily.InterNetwork, single.AddressFamily);
        Assert.Equal(LanAddress.GetAddressBytes(), single.GetAddressBytes());
    }

    [Fact]
    public void Address_coverage_rejects_certificates_without_a_san_extension()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest(
            "CN=ShadowPlay Local",
            key,
            HashAlgorithmName.SHA256);
        using var bareCertificate = request.CreateSelfSigned(
            NotBefore, NotBefore.AddDays(30));

        Assert.False(HttpsIdentityService.CoversAddresses(bareCertificate, [LanAddress]));
    }

    [Fact]
    public void San_parsing_rejects_malformed_extensions()
    {
        // A SEQUENCE that claims more content than it carries: strict DER
        // reading must reject without throwing out of the parser.
        var parsed = HttpsIdentityService.TryParseSubjectAlternativeNames(
            [0x30, 0x05, 0x82, 0x01], out var dnsNames, out var addresses);

        Assert.False(parsed);
        Assert.Empty(dnsNames);
        Assert.Empty(addresses);
    }

    [Fact]
    public void Thumbprint_is_the_uppercase_sha256_of_the_der_certificate()
    {
        // The QR code and server DTO both advertise the SHA-256 of the DER
        // leaf; phones pin exactly that value.
        using var certificate = HttpsIdentityService.CreateCertificate(
            [LanAddress], NotBefore);

        var digest = SHA256.HashData(certificate.Export(X509ContentType.Cert));
        var expected = Convert.ToHexString(digest);

        Assert.Equal(expected, certificate.GetCertHashString(HashAlgorithmName.SHA256));
    }
}
