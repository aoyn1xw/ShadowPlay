using Xunit;
using System.Text;
using ShadowPlay.Core;
using ShadowPlay.Core.Pairing;

namespace ShadowPlay.Tests;

public class TokenFormatTests
{
    [Fact]
    public void Base64url_encoding_contains_only_url_safe_characters()
    {
        // Deterministic bytes that produce '+' and '/' in standard base64.
        var bytes = new byte[] { 0xFB, 0xFF, 0xBF, 0xFE, 0xEF, 0xBE };

        var encoded = Base64Url.Encode(bytes);

        Assert.DoesNotContain("+", encoded, StringComparison.Ordinal);
        Assert.DoesNotContain("/", encoded, StringComparison.Ordinal);
        Assert.DoesNotContain("=", encoded, StringComparison.Ordinal);
        Assert.DoesNotContain('\0', encoded);

        Assert.Equal(bytes, Base64Url.Decode(encoded));
    }

    [Fact]
    public void Bearer_tokens_are_long_and_random_with_no_control_characters()
    {
        var generator = new SecureTokenGenerator();
        var seen = new HashSet<string>();

        for (var i = 0; i < 100; i++)
        {
            var token = generator.CreateBearerToken();

            Assert.InRange(token.Length, 40, 60); // ~43 chars for 32 bytes
            Assert.All(token, c => Assert.False(char.IsControl(c)));
            Assert.True(Uri.IsWellFormedUriString(token, UriKind.Relative)); // header-safe
            seen.Add(token);
        }

        Assert.Equal(100, seen.Count); // uniqueness
    }

    [Fact]
    public void Pairing_codes_are_well_formed()
    {
        var generator = new SecureTokenGenerator();

        for (var i = 0; i < 50; i++)
        {
            Assert.Matches("^[0-9A-Z]{4}-[0-9A-Z]{4}$", generator.CreatePairingCode());
        }
    }

    [Fact]
    public void Sha256_hashing_is_deterministic_and_hex()
    {
        var a = Hashing.Sha256Hex("hello");
        var b = Hashing.Sha256Hex("hello");
        var c = Hashing.Sha256Hex("hellO");

        Assert.Equal(a, b);
        Assert.NotEqual(a, c);
        Assert.Matches("^[0-9A-F]{64}$", a);
    }
}
