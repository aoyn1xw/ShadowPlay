using System.Diagnostics.CodeAnalysis;

namespace ShadowPlay.Core.Validation;

/// <summary>
/// Validates that a folder exists and can be enumerated. Performs no writes.
/// </summary>
public sealed class FolderValidator : IFolderValidator
{
    public FolderValidationResult Validate(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return FolderValidationResult.Fail("Please choose a recordings folder.");
        }

        string fullPath;
        try
        {
            fullPath = Path.GetFullPath(path);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or System.Security.SecurityException or IOException)
        {
            return FolderValidationResult.Fail("That folder path is not valid.");
        }

        if (!Directory.Exists(fullPath))
        {
            return FolderValidationResult.Fail($"The folder does not exist:\n{fullPath}");
        }

        try
        {
            // Force an actual read to confirm the folder is accessible.
            using var enumerator = Directory.EnumerateFileSystemEntries(fullPath).GetEnumerator();
            enumerator.MoveNext();
        }
        catch (UnauthorizedAccessException)
        {
            return FolderValidationResult.Fail($"Access denied. ShadowPlay needs read permission for:\n{fullPath}");
        }
        catch (IOException ex)
        {
            return FolderValidationResult.Fail($"The folder could not be read:\n{fullPath}\n({ex.HResult & 0xFFFF})");
        }
        catch (Exception)
        {
            return FolderValidationResult.Fail($"The folder could not be read:\n{fullPath}");
        }

        return FolderValidationResult.Ok;
    }
}
