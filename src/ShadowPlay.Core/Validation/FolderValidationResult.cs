namespace ShadowPlay.Core.Validation;

/// <summary>Result of validating a user-selected recordings folder.</summary>
public sealed record FolderValidationResult(bool IsValid, string? Error = null)
{
    public static readonly FolderValidationResult Ok = new(true);

    public static FolderValidationResult Fail(string error) => new(false, error);
}
