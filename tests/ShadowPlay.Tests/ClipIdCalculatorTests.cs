using Xunit;
using ShadowPlay.Core.Clips;

namespace ShadowPlay.Tests;

public class ClipIdCalculatorTests
{
    [Fact]
    public void Id_is_stable_for_the_same_path()
    {
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "id_test.mp4");
        var a = ClipIdCalculator.Calculate(path);
        var b = ClipIdCalculator.Calculate(path);
        Assert.Equal(a, b);
    }

    [Fact]
    public void Id_is_case_insensitive_on_windows_paths()
    {
        var lower = ClipIdCalculator.Calculate(@"c:\videos\match.mp4");
        var upper = ClipIdCalculator.Calculate(@"C:\VIDEOS\MATCH.mp4");
        Assert.Equal(lower, upper);
    }

    [Fact]
    public void Id_is_opaque_and_does_not_reveal_the_path()
    {
        var id = ClipIdCalculator.Calculate(@"c:\users\secretuser\my clips\holiday.mp4");

        Assert.Matches("^[0-9A-F]{64}$", id); // 64 uppercase hex chars
        Assert.DoesNotContain("\\", id, StringComparison.Ordinal);
        Assert.DoesNotContain("/", id, StringComparison.Ordinal);
        Assert.DoesNotContain("holiday", id, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Different_files_get_different_ids()
    {
        var a = ClipIdCalculator.Calculate(@"c:\clips\one.mp4");
        var b = ClipIdCalculator.Calculate(@"c:\clips\two.mp4");
        Assert.NotEqual(a, b);
    }
}
