using System.Security.Cryptography;

namespace ShadowPlay.Core.Pairing;

public static class Hashing
{
    /// <summary>SHA-256 of the input as 64 uppercase hex characters. Used for bearer-token storage.</summary>
    public static string Sha256Hex(string input)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(input);
        return Convert.ToHexString(SHA256.HashData(bytes));
    }

    /// <summary>Constant-time comparison of two hex strings.</summary>
    public static bool FixedTimeEqualsHex(string a, string b)
    {
        if (a.Length != b.Length)
        {
            return false;
        }

        return CryptographicOperations.FixedTimeEquals(System.Text.Encoding.ASCII.GetBytes(a), System.Text.Encoding.ASCII.GetBytes(b));
    }
}
