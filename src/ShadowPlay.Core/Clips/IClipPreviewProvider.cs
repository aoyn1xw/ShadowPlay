using ShadowPlay.Core.Models;

namespace ShadowPlay.Core.Clips;

/// <summary>
/// Supplies media metadata and optional previews without exposing host paths to API clients.
/// Implementations may cache expensive work on the desktop side.
/// </summary>
public interface IClipPreviewProvider
{
    bool SupportsThumbnails { get; }

    TimeSpan? GetDuration(string fullPath);

    byte[]? GetThumbnail(ClipEntry entry);
}
