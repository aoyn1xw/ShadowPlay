using System.Security.Cryptography;

namespace ShadowPlay.Core.Pairing;

/// <summary>Creates cryptographically random secrets.</summary>
public interface ISecretGenerator
{
    /// <summary>A long-lived bearer token, base64url-encoded, ~32 bytes of entropy.</summary>
    string CreateBearerToken();

    /// <summary>An 8-character pairing code from an unambiguous alphabet, formatted "XXXX-XXXX".</summary>
    string CreatePairingCode();
}

public sealed class SecureTokenGenerator : ISecretGenerator
{
    private const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford base32 (no I, L, O, U)
    private const int CodeLength = 8;

    public string CreateBearerToken()
    {
        Span<byte> bytes = stackalloc byte[32];
        RandomNumberGenerator.Fill(bytes);
        return Base64Url.Encode(bytes);
    }

    public string CreatePairingCode()
    {
        Span<char> chars = stackalloc char[CodeLength + 1];
        for (var i = 0; i < CodeLength; i++)
        {
            var target = i < 4 ? i : i + 1; // leave room for the dash
            chars[target] = Alphabet[RandomNumberGenerator.GetInt32(Alphabet.Length)];
        }

        chars[4] = '-';
        return new string(chars);
    }
}
