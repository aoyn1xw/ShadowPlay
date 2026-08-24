using System.Security.Cryptography;

namespace ShadowPlay.Tests;

/// <summary>A self-cleaning temporary directory for filesystem tests.</summary>
public sealed class TempFolder : IDisposable
{
    public string Path { get; }

    public TempFolder()
    {
        Path = Directory.CreateTempSubdirectory("shadowplay_test_").FullName;
    }

    /// <summary>Writes a dummy .mp4 with random bytes. Returns the full path.</summary>
    public string CreateMp4(string relativeName, int sizeBytes = 1024, DateTimeOffset? lastWrite = null)
    {
        var fullPath = System.IO.Path.Combine(Path, relativeName);
        var dir = System.IO.Path.GetDirectoryName(fullPath)!;
        Directory.CreateDirectory(dir);

        var content = RandomNumberGenerator.GetBytes(sizeBytes);
        // Minimal MP4-ish signature so the file looks plausible.
        content[4] = (byte)'f';
        content[5] = (byte)'t';
        content[6] = (byte)'y';
        content[7] = (byte)'p';

        File.WriteAllBytes(fullPath, content);
        if (lastWrite is not null)
        {
            File.SetLastWriteTimeUtc(fullPath, lastWrite.Value.UtcDateTime);
        }

        return fullPath;
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}
