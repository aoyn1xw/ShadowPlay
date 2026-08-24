using System.Text;

namespace ShadowPlay.Core.Clips;

/// <summary>
/// Produces safe download filenames for the Content-Disposition header.
/// Strips control characters, path separators and reserved names; never trusts client input.
/// </summary>
public static class SafeFileName
{
    private static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    public static string For(string? originalName)
    {
        var name = (originalName ?? string.Empty).Trim();

        // Take only the file name portion; never allow directory components.
        name = Path.GetFileName(name);

        var sb = new StringBuilder(name.Length);
        foreach (var ch in name)
        {
            if (char.IsControl(ch) || Path.GetInvalidFileNameChars().Contains(ch))
            {
                sb.Append('_');
            }
            else
            {
                sb.Append(ch);
            }
        }

        name = sb.ToString().Trim(' ', '.');

        if (name.Length == 0)
        {
            return "clip.mp4";
        }

        if (name.Length > 120)
        {
            var ext = Path.GetExtension(name);
            name = string.Concat(name.AsSpan(0, Math.Max(1, 120 - ext.Length)), ext);
        }

        var stem = Path.GetFileNameWithoutExtension(name);
        if (ReservedNames.Contains(stem))
        {
            name = "_" + name;
        }

        return name;
    }
}
