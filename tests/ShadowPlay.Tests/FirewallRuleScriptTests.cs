using ShadowPlay.Windows.Services;
using Xunit;

namespace ShadowPlay.Tests;

/// <summary>
/// Verifies the generated Windows Firewall netsh script (shelled out through
/// an encoded PowerShell command by the desktop app): one private-profile TCP
/// rule per listener port, replace-or-add semantics, and the legacy
/// single-port rule being torn down so migration to per-port rules cannot
/// leave stale open ports behind.
/// </summary>
public sealed class FirewallRuleScriptTests
{
    private const string ShadowPlayPath = @"C:\Program Files\ShadowPlay\ShadowPlay.exe";

    [Fact]
    public void Rule_names_are_prefixed_and_port_suffixed()
    {
        Assert.Equal(WindowsFirewallService.RuleName, "ShadowPlay LAN API (Private)");
        Assert.StartsWith(WindowsFirewallService.RuleNamePrefix, WindowsFirewallService.RuleNameFromPort(5177));
        Assert.EndsWith("5177", WindowsFirewallService.RuleNameFromPort(5177));
    }

    [Fact]
    public void Script_adds_one_private_tcp_rule_per_port()
    {
        var script = WindowsFirewallService.BuildRuleScript(ShadowPlayPath, [5177, 5178]);

        Assert.Contains(
            "add rule name='ShadowPlay LAN API (Private) TCP 5177' dir=in action=allow "
            + "protocol=TCP localport=5177 profile=private "
            + $"program='{ShadowPlayPath}' enable=yes",
            script,
            StringComparison.Ordinal);
        Assert.Contains(
            "add rule name='ShadowPlay LAN API (Private) TCP 5178' dir=in action=allow "
            + "protocol=TCP localport=5178 profile=private "
            + $"program='{ShadowPlayPath}' enable=yes",
            script,
            StringComparison.Ordinal);
        Assert.Equal(2, CountOccurrences(script, "add rule"));
    }

    [Fact]
    public void Script_tears_down_the_legacy_single_port_rule()
    {
        // Migration: the old wide-open rule named without a port suffix must
        // be deleted, or the pre-HTTPS port stays reachable forever.
        var script = WindowsFirewallService.BuildRuleScript(ShadowPlayPath, [5177]);

        Assert.Contains($"delete rule name='{WindowsFirewallService.RuleName}'", script);
    }

    [Fact]
    public void Script_deletes_a_port_rule_before_readding_it()
    {
        var script = WindowsFirewallService.BuildRuleScript(ShadowPlayPath, [5177]);
        var ruleName = WindowsFirewallService.RuleNameFromPort(5177);

        var deleteIndex = script.IndexOf($"delete rule name='{ruleName}'", StringComparison.Ordinal);
        var addIndex = script.IndexOf($"add rule name='{ruleName}'", StringComparison.Ordinal);

        Assert.True(deleteIndex >= 0, "the per-port rule must be deleted");
        Assert.True(addIndex >= 0, "the per-port rule must be re-added");
        Assert.True(deleteIndex < addIndex, "delete must precede add (replace-or-add)");
    }

    [Fact]
    public void Script_neutralizes_single_quotes_in_the_program_path()
    {
        const string apostrophePath = @"C:\Users\O'Brien\AppData\Local\ShadowPlay.exe";
        var script = WindowsFirewallService.BuildRuleScript(apostrophePath, [5177]);

        Assert.Contains("O''Brien", script, StringComparison.Ordinal);
        Assert.DoesNotContain(@"Users\O'Brien\", script, StringComparison.Ordinal);
    }

    [Fact]
    public void Duplicate_ports_do_not_emit_duplicate_rules()
    {
        var script = WindowsFirewallService.BuildRuleScript(ShadowPlayPath, [5177, 5177, 5178]);

        Assert.Equal(2, CountOccurrences(script, "add rule"));
        Assert.Equal(1, CountOccurrences(script, "add rule name='ShadowPlay LAN API (Private) TCP 5177'"));
        Assert.Equal(1, CountOccurrences(script, "delete rule name='ShadowPlay LAN API (Private) TCP 5177'"));
    }

    [Fact]
    public void Script_exits_with_the_last_status_code()
    {
        var script = WindowsFirewallService.BuildRuleScript(ShadowPlayPath, [5177]);

        Assert.StartsWith("$ErrorActionPreference='Stop'; ", script, StringComparison.Ordinal);
        Assert.EndsWith("exit $LASTEXITCODE", script, StringComparison.Ordinal);
    }

    private static int CountOccurrences(string text, string needle)
    {
        var count = 0;
        var index = 0;
        while ((index = text.IndexOf(needle, index, StringComparison.Ordinal)) >= 0)
        {
            count++;
            index += needle.Length;
        }

        return count;
    }
}
