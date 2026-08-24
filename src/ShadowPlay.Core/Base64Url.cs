namespace ShadowPlay.Core;

/// <summary>RFC 4648 base64url (no padding), dependency-free.</summary>
public static class Base64Url
{
    public static string Encode(ReadOnlySpan<byte> bytes)
    {
        var base64 = Convert.ToBase64String(bytes);

        // Strip padding first so the result length is exact (no stray padding chars).
        var contentLength = base64.Length;
        while (contentLength > 0 && base64[contentLength - 1] == '=')
        {
            contentLength--;
        }

        return string.Create(contentLength, base64, static (span, source) =>
        {
            for (var i = 0; i < span.Length; i++)
            {
                span[i] = source[i] switch
                {
                    '+' => '-',
                    '/' => '_',
                    var ch => ch,
                };
            }
        });
    }

    /// <summary>Decodes unpadded base64url back to bytes.</summary>
    public static byte[] Decode(string value)
    {
        var replaced = value.Replace('-', '+').Replace('_', '/');
        switch (replaced.Length % 4)
        {
            case 2: replaced += "=="; break;
            case 3: replaced += "="; break;
            case 0: break;
            default: throw new FormatException("Invalid base64url length.");
        }

        return Convert.FromBase64String(replaced);
    }
}
