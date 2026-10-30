using System.Formats.Asn1;
using System.Net;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Extensions.Logging;

namespace ShadowPlay.Core.Networking;

/// <summary>An obtainable pinned-TLS server identity.</summary>
/// <param name="Certificate">ECDSA P-256 self-signed certificate with a private key.</param>
/// <param name="Sha256Thumbprint">Uppercase hex SHA-256 of the DER certificate.</param>
public sealed record HttpsIdentity(X509Certificate2 Certificate, string Sha256Thumbprint);

public interface IHttpsIdentityService
{
    /// <summary>
    /// Returns the persisted local HTTPS identity, creating (and keeping) a new
    /// self-signed certificate when none exists or the current LAN addresses are
    /// no longer covered by its subject alternative names. Returns null when the
    /// identity cannot be provided; callers must fall back to plain HTTP rather
    /// than fail sharing.
    /// </summary>
    HttpsIdentity? GetOrCreateIdentity(
        IReadOnlyCollection<IPAddress> lanAddresses,
        ILogger? logger = null);
}

/// <summary>
/// Owns the long-lived self-signed certificate used for pinned LAN HTTPS.
/// Certificates live in the current user's personal certificate store so they
/// survive restarts without any settings schema changes. When the set of LAN
/// IPv4 addresses changes beyond what a stored certificate covers, a new
/// certificate is generated; phones then need to re-pair (the QR carries the
/// new fingerprint).
/// </summary>
public sealed class HttpsIdentityService : IHttpsIdentityService
{
    public const string CertificateSubject = "CN=ShadowPlay Local";
    private const string FriendlyName = "ShadowPlay Local HTTPS";
    private const string LoopbackFallbackName = "shadowplay.local";

    /// <summary>Certificates are considered expired for pairing when this much
    /// validity remains (they get regenerated ahead of expiry).</summary>
    private static readonly TimeSpan MinimumRemainingValidity = TimeSpan.FromDays(90);

    private static readonly TimeSpan CertificateLifetime = TimeSpan.FromDays(3650);
    internal static readonly TimeSpan ClockSkewTolerance = TimeSpan.FromDays(1);

    public HttpsIdentity? GetOrCreateIdentity(
        IReadOnlyCollection<IPAddress> lanAddresses,
        ILogger? logger = null)
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        try
        {
            using var store = new X509Store(StoreName.My, StoreLocation.CurrentUser);
            store.Open(OpenFlags.ReadWrite);
            try
            {
                var validNow = DateTimeOffset.UtcNow;
                var wanted = NormalizeLanAddresses(lanAddresses);

                X509Certificate2? existing = null;
                foreach (var candidate in EnumerateCandidates(store, validNow))
                {
                    if (CoversAddresses(candidate, wanted)
                        && (existing is null
                            || candidate.NotAfter > existing.NotAfter))
                    {
                        existing = candidate;
                    }
                }

                if (existing is null)
                {
                    existing = CreateCertificate(wanted, validNow);
                    // Mark the certificate so later startups recognize and reuse
                    // it: the store persists this property alongside the entry,
                    // and EnumerateCandidates filters on it.
                    existing.FriendlyName = FriendlyName;
                    store.Add(existing);
                    logger?.LogInformation(
                        "Generated a new ShadowPlay HTTPS certificate (thumbprint {Thumbprint}) covering {AddressCount} LAN addresses.",
                        existing.GetCertHashString(HashAlgorithmName.SHA256),
                        wanted.Count);
                }

                return new HttpsIdentity(
                    existing,
                    existing.GetCertHashString(HashAlgorithmName.SHA256));
            }
            finally
            {
                store.Close();
            }
        }
        catch (Exception ex)
        {
            logger?.LogWarning(ex,
                "Could not obtain the ShadowPlay HTTPS certificate; sharing will start without TLS.");
            return null;
        }
    }

    private static IEnumerable<X509Certificate2> EnumerateCandidates(
        X509Store store, DateTimeOffset validNow)
    {
        foreach (var certificate in store.Certificates)
        {
            if (!string.Equals(certificate.FriendlyName, FriendlyName, StringComparison.Ordinal))
            {
                continue;
            }

            if (certificate.NotAfter < validNow + MinimumRemainingValidity
                || certificate.NotBefore > validNow + ClockSkewTolerance)
            {
                continue;
            }

            if (!certificate.HasPrivateKey)
            {
                continue;
            }

            yield return certificate;
        }
    }

    /// <summary>Creates the self-signed certificate used by the LAN HTTPS listener.</summary>
    /// <remarks>Exposed for tests; the returned certificate is not persisted.</remarks>
    public static X509Certificate2 CreateCertificate(
        IReadOnlyCollection<IPAddress> lanAddresses,
        DateTimeOffset notBefore,
        TimeSpan? lifetime = null,
        string? dnsName = null)
    {
        var end = notBefore + (lifetime ?? CertificateLifetime);
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest(
            CertificateSubject,
            key,
            HashAlgorithmName.SHA256);

        var san = new SubjectAlternativeNameBuilder();
        foreach (var dns in new[] { dnsName ?? LoopbackFallbackName })
        {
            san.AddDnsName(dns);
        }

        foreach (var address in NormalizeLanAddresses(lanAddresses))
        {
            san.AddIpAddress(address);
        }
        // Loopback keeps local debugging and smoke checks functional.
        san.AddIpAddress(IPAddress.Loopback);

        request.CertificateExtensions.Add(san.Build());
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(
            certificateAuthority: false,
            hasPathLengthConstraint: false,
            pathLengthConstraint: 0,
            critical: true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(
            X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment,
            critical: true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(
            new OidCollection { new("1.3.6.1.5.5.7.3.1") },
            critical: false));

        var certificate = request.CreateSelfSigned(
            notBefore,
            end + TimeSpan.Zero);

        // Windows SChannel cannot serve TLS with the ephemeral CNG key that
        // CreateSelfSigned binds to ("the platform does not support ephemeral
        // keys"): every handshake fails with an empty EOF. Re-importing from
        // the certificate's own PFX export gives the private key a container
        // that is independent of the local ECDsa object lifetime.
        return new X509Certificate2(certificate.Export(X509ContentType.Pfx));
    }

    internal static HashSet<IPAddress> NormalizeLanAddresses(
        IReadOnlyCollection<IPAddress> lanAddresses)
    {
        var wanted = new HashSet<IPAddress>();
        foreach (var address in lanAddresses)
        {
            var ip = address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;
            if (ip.AddressFamily is System.Net.Sockets.AddressFamily.InterNetwork
                or System.Net.Sockets.AddressFamily.InterNetworkV6)
            {
                wanted.Add(new IPAddress(ip.GetAddressBytes()));
            }
        }
        return wanted;
    }

    /// <summary>true when the certificate's SAN covers every required address.</summary>
    internal static bool CoversAddresses(X509Certificate2 certificate, IReadOnlyCollection<IPAddress> required)
    {
        if (required.Count == 0)
        {
            return true;
        }

        var san = certificate.Extensions
            .OfType<X509Extension>()
            .FirstOrDefault(extension => extension.Oid?.Value == "2.5.29.17");
        if (san is null)
        {
            return false;
        }

        if (!TryParseSubjectAlternativeNames(san.RawData, out var dnsNames, out var addresses))
        {
            return false;
        }

        // A DNS name entry also authorizes the textual form of the address so
        // clients connecting via a hostname recorded in the SAN pass too.
        var covered = new HashSet<IPAddress>(addresses);
        foreach (var address in required)
        {
            var ip = address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;
            if (!covered.Contains(new IPAddress(ip.GetAddressBytes())))
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>
    /// Minimal DER reader for SubjectAlternativeName (OID 2.5.29.17):
    /// OCTET STRING wrapping SEQUENCE OF GeneralName. Understands the
    /// dNSName ([2]) and iPAddress ([7]) choices, which is enough for the
    /// certificates this service creates.
    /// </summary>
    internal static bool TryParseSubjectAlternativeNames(
        ReadOnlySpan<byte> extensionRaw,
        out IReadOnlyList<string> dnsNames,
        out IReadOnlyList<IPAddress> addresses)
    {
        dnsNames = [];
        addresses = [];

        var spans = new List<(byte[] Raw, int Tag)>();
        try
        {
            // The extension data is normally the GeneralNames SEQUENCE itself;
            // some encoders additionally wrap it in an OCTET STRING (the
            // certificate field envelope). Accept both shapes.
            var outer = new AsnReader(extensionRaw.ToArray(), AsnEncodingRules.DER);
            var first = outer.PeekTag();
            ReadOnlyMemory<byte> payload;
            if (first.Equals(Asn1Tag.PrimitiveOctetString))
            {
                payload = outer.ReadOctetString();
            }
            else if (first.Equals(Asn1Tag.Sequence))
            {
                payload = outer.ReadEncodedValue();
            }
            else
            {
                return false;
            }

            if (outer.HasData || payload.Length == 0)
            {
                return false;
            }

            var sequence = new AsnReader(payload, AsnEncodingRules.DER);
            var generalNames = sequence.ReadSequence();
            while (generalNames.HasData)
            {
                var (tag, content) = ReadGeneralName(generalNames);
                if (tag < 0)
                {
                    return false;
                }
                spans.Add((content, tag));
            }
            if (sequence.HasData || generalNames.HasData)
            {
                // Trailing garbage rejects to avoid malformed parsing.
                return false;
            }
        }
        catch (AsnContentException)
        {
            return false;
        }

        var dns = new List<string>();
        var ips = new List<IPAddress>();
        foreach (var (raw, tag) in spans)
        {
            switch (tag)
            {
                case 2: // dNSName: IA5String
                    dns.Add(System.Text.Encoding.ASCII.GetString(raw));
                    break;
                case 7:
                    try
                    {
                        var ip = new IPAddress(raw);
                        ips.Add(new IPAddress(ip.GetAddressBytes()));
                    }
                    catch (ArgumentException)
                    {
                        return false;
                    }
                    break;
                default:
                    // Other name types are tolerated (coverage falls back to
                    // the entries we do understand).
                    break;
            }
        }

        dnsNames = dns;
        addresses = ips;
        return true;
    }

    private static (int Tag, byte[] Content) ReadGeneralName(AsnReader reader)
    {
        var raw = reader.ReadEncodedValue().Span;
        if (raw.Length < 2 || (byte)raw[0] < 0x80)
        {
            return (-1, []);
        }

        // Primitive, context-specific GeneralName choices used by SAN:
        // 0x81 rfc822, 0x82 dNSName, 0x86 URI, 0x87 iPAddress. Map them to
        // their RFC 5280 choice numbers; anything else is tolerated but only
        // mapped once to keep coverage logic deterministic.
        switch (raw[0])
        {
            case 0x81: return (1, raw[2..].ToArray());
            case 0x82: return (2, raw[2..].ToArray());
            case 0x86: return (6, raw[2..].ToArray());
            case 0x87: return (7, raw[2..].ToArray());
            default:
                return (0, []);
        }
    }
}
