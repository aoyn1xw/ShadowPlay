namespace ShadowPlay.Core.Clips;

/// <summary>
/// Recursively scans a recordings root for .mp4 files without following into
/// inaccessible subdirectories. Read-only; never modifies anything.
/// </summary>
public static class RecordingScanner
{
    public static List<(string FullPath, long SizeBytes, DateTimeOffset LastWriteTimeUtc)> Scan(
        string rootFolder,
        CancellationToken cancellationToken = default)
    {
        var results = new List<(string, long, DateTimeOffset)>();

        var options = new EnumerationOptions
        {
            IgnoreInaccessible = true,
            RecurseSubdirectories = true,
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System,
            ReturnSpecialDirectories = false,
        };

        try
        {
            foreach (var path in Directory.EnumerateFiles(rootFolder, "*.mp4", options))
            {
                cancellationToken.ThrowIfCancellationRequested();

                FileInfo? info;
                try
                {
                    info = new FileInfo(path);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    continue;
                }

                if (!info.Exists || IsTempRecordingName(info.Name))
                {
                    continue;
                }

                results.Add((info.FullName, info.Length, new DateTimeOffset(info.LastWriteTimeUtc)));
            }
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Root temporarily unavailable; return what we have.
        }

        return results;
    }

    /// <summary>NVIDIA-style temp names that must never be published.</summary>
    public static bool IsTempRecordingName(string fileName)
    {
        var name = Path.GetFileName(fileName);
        return name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase)
               || name.StartsWith('~')
               || name.StartsWith("._temp_", StringComparison.OrdinalIgnoreCase);
    }
}
