using Xunit;
using ShadowPlay.Core.Clips;

namespace ShadowPlay.Tests;

public class SafeFileNameTests
{
    [Fact]
    public void Normal_name_passes_through()
    {
        Assert.Equal("clip.mp4", SafeFileName.For("clip.mp4"));
    }

    [Fact]
    public void Directory_components_are_removed()
    {
        Assert.Equal("evil.mp4", SafeFileName.For(@"..\..\windows\system32\evil.mp4"));
        Assert.Equal("evil.mp4", SafeFileName.For("sub/dir/evil.mp4"));
    }

    [Fact]
    public void Control_and_invalid_characters_are_replaced()
    {
        var result = SafeFileName.For("bad\u0000name:with*chars?.mp4");
        Assert.DoesNotContain('\0', result);
        Assert.DoesNotContain(':', result);
        Assert.DoesNotContain('*', result);
        Assert.EndsWith(".mp4", result, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Empty_names_fall_back()
    {
        Assert.Equal("clip.mp4", SafeFileName.For(""));
        Assert.Equal("clip.mp4", SafeFileName.For(null));
        Assert.Equal("clip.mp4", SafeFileName.For("  ..  "));
    }

    [Fact]
    public void Reserved_device_names_are_prefixed()
    {
        var result = SafeFileName.For("CON.mp4");
        Assert.NotEqual("CON.mp4", result);
        Assert.StartsWith("_", result, StringComparison.Ordinal);
    }

    [Fact]
    public void Very_long_names_are_truncated_but_keep_extension()
    {
        var longName = new string('a', 300) + ".mp4";
        var result = SafeFileName.For(longName);
        Assert.True(result.Length <= 130);
        Assert.EndsWith(".mp4", result, StringComparison.OrdinalIgnoreCase);
    }
}
