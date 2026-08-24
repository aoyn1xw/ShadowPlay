namespace ShadowPlay.Core.Validation;

public interface IFolderValidator
{
    /// <summary>Validates that the folder exists and is readable.</summary>
    FolderValidationResult Validate(string? path);
}
