namespace ShadowPlay.Core.Clips;

/// <summary>
/// Confirms a recording can actually be opened for reading before it is published.
/// Opens with FileShare.ReadWrite so an active writer is not disturbed.
/// </summary>
public static class FileReadProbe
{
    public static bool CanOpenForRead(string fullPath)
    {
        try
        {
            using var stream = new FileStream(
                fullPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read | FileShare.Delete);
            return stream.CanRead;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }
}
