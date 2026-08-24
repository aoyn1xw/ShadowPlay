using System.Security.Cryptography;
using System.Text;

namespace ShadowPlay.Core.Clips;

/// <summary>
/// Produces stable, opaque clip IDs: SHA-256 of the case-normalized full path.
/// The ID reveals nothing about the filesystem layout and is deterministic across restarts.
/// </summary>
public static class ClipIdCalculator
{
    public static string Calculate(string fullPath)
    {
        var normalized = Path.GetFullPath(fullPath).ToLowerInvariant();
        var bytes = Encoding.UTF8.GetBytes(normalized);
        var hash = SHA256.HashData(bytes);
        return Convert.ToHexString(hash); // 64 uppercase hex chars
    }
}
