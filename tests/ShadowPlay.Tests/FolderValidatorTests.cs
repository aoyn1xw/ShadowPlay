using Xunit;
using ShadowPlay.Core.Validation;

namespace ShadowPlay.Tests;

public class FolderValidatorTests : IDisposable
{
    private readonly TempFolder _folder = new();
    private readonly FolderValidator _validator = new();

    [Fact]
    public void Null_path_is_invalid()
    {
        var result = _validator.Validate(null);
        Assert.False(result.IsValid);
        Assert.NotNull(result.Error);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void Empty_path_is_invalid(string path)
    {
        Assert.False(_validator.Validate(path).IsValid);
    }

    [Fact]
    public void Nonexistent_folder_is_invalid()
    {
        var missing = System.IO.Path.Combine(_folder.Path, "does_not_exist");
        var result = _validator.Validate(missing);

        Assert.False(result.IsValid);
        Assert.Contains("does not exist", result.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Existing_empty_folder_is_valid()
    {
        Assert.True(_validator.Validate(_folder.Path).IsValid);
    }

    [Fact]
    public void Folder_with_content_is_readable_and_valid()
    {
        _folder.CreateMp4("clip.mp4");
        Assert.True(_validator.Validate(_folder.Path).IsValid);
    }

    [Fact]
    public void A_file_path_is_rejected_as_folder()
    {
        var file = _folder.CreateMp4("actually_a_file.mp4");
        // Directory.Exists returns false for files, so this must not be valid.
        Assert.False(_validator.Validate(file).IsValid);
    }

    public void Dispose() => _folder.Dispose();
}
