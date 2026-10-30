using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Extensions.Logging;

namespace ShadowPlay.Windows.Services;

public enum FirewallRuleState
{
    Ready,
    Missing,
    Mismatched,
    BlockedByNetworkProfile,
    Unavailable,
}

public sealed record FirewallStatus(
    FirewallRuleState State,
    string Detail,
    bool PrivateNetworkActive)
{
    public bool NeedsSetup => State is not FirewallRuleState.Ready;
}

public interface IWindowsFirewallService
{
    FirewallStatus Check(string executablePath, int port);

    Task<FirewallStatus> EnsurePrivateRuleAsync(string executablePath, int port);

    /// <summary>Checks one private-profile TCP rule per requested port.</summary>
    FirewallStatus Check(string executablePath, IReadOnlyCollection<int> ports);

    /// <summary>
    /// Ensures one private-profile inbound TCP rule per requested port
    /// (e.g. the HTTP listener and the pinned-TLS listener).
    /// </summary>
    Task<FirewallStatus> EnsurePrivateRuleAsync(string executablePath, IReadOnlyCollection<int> ports);
}

/// <summary>
/// Checks and explicitly provisions one inbound TCP rule per port for the current
/// ShadowPlay executable. Rules are private-profile-only; this service never enables
/// Windows Firewall or opens a public-profile port.
/// </summary>
public sealed class WindowsFirewallService(ILogger<WindowsFirewallService>? logger = null)
    : IWindowsFirewallService
{
    /// <summary>Legacy single-port rule name (kept so upgrades replace it).</summary>
    public const string RuleName = "ShadowPlay LAN API (Private)";

    /// <summary>Per-port rules are named `ShadowPlay LAN API (Private) TCP {port}`.</summary>
    public const string RuleNamePrefix = "ShadowPlay LAN API (Private) TCP ";

    private const int Inbound = 1;
    private const int Tcp = 6;
    private const int Allow = 1;
    private const int PrivateProfile = 2;

    public FirewallStatus Check(string executablePath, int port)
        => Check(executablePath, [port]);

    public FirewallStatus Check(string executablePath, IReadOnlyCollection<int> ports)
    {
        if (ports.Count == 0)
        {
            return new(
                FirewallRuleState.Unavailable,
                "No listener ports are configured for the sharing service.",
                false);
        }

        if (!OperatingSystem.IsWindows())
        {
            return new(
                FirewallRuleState.Unavailable,
                "Windows Firewall checks are only available on Windows.",
                false);
        }

        try
        {
            var policyType = Type.GetTypeFromProgID("HNetCfg.FwPolicy2", throwOnError: true)!;
            dynamic policy = Activator.CreateInstance(policyType)!;
            try
            {
                // CurrentProfileTypes is a bitmask across every connected adapter.
                // A disconnected Private VPN/Tailscale adapter must not make a
                // Public Wi-Fi profile look safe for a Private-only rule.
                var privateActive = IsActivePrivateNetworkProfile();
                var expectedPath = NormalizePath(executablePath);
                var matchingPorts = new HashSet<int>();
                var stalePorts = new HashSet<int>();

                dynamic rules = policy.Rules;
                foreach (dynamic rule in rules)
                {
                    var name = (string?)rule.Name;
                    if (string.IsNullOrEmpty(name))
                    {
                        continue;
                    }

                    // Match both the legacy single-port name and the per-port names.
                    if (!string.Equals(name, RuleName, StringComparison.Ordinal)
                        && !name.StartsWith(RuleNamePrefix, StringComparison.Ordinal))
                    {
                        continue;
                    }

                    // A rule may list several local ports; evaluate each.
                    var localPorts = ((string?)rule.LocalPorts ?? string.Empty)
                        .Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
                    foreach (var value in localPorts)
                    {
                        if (!int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var rulePort))
                        {
                            continue;
                        }

                        if (Matches(rule, expectedPath, rulePort))
                        {
                            matchingPorts.Add(rulePort);
                        }
                        else
                        {
                            stalePorts.Add(rulePort);
                        }
                    }
                }

                var missing = ports.Where(port => !matchingPorts.Contains(port)).ToList();
                if (missing.Count == 0)
                {
                    var portList = string.Join(", ", ports);
                    if (privateActive)
                    {
                        return new(
                            FirewallRuleState.Ready,
                            $"Private firewall rules are active for TCP {portList}.",
                            true);
                    }

                    return new(
                        FirewallRuleState.BlockedByNetworkProfile,
                        "The rules are private-only, but the active Wi-Fi network is not marked Private.",
                        false);
                }

                var stale = stalePorts.Count > 0
                    ? $" Stale rules exist for TCP {string.Join(", ", stalePorts)}."
                    : string.Empty;
                return new(
                    FirewallRuleState.Mismatched,
                    $"No private-only ShadowPlay firewall rules cover TCP {string.Join(", ", missing)}.{stale}",
                    privateActive);
            }
            finally
            {
                ReleaseCom(policy);
            }
        }
        catch (Exception ex) when (ex is COMException or InvalidComObjectException or UnauthorizedAccessException or InvalidOperationException)
        {
            logger?.LogWarning(ex, "Unable to inspect the Windows Firewall rule");
            return new(
                FirewallRuleState.Unavailable,
                "Windows Firewall status could not be inspected. Run ShadowPlay as administrator or check the rule manually.",
                false);
        }
    }

    public Task<FirewallStatus> EnsurePrivateRuleAsync(string executablePath, int port)
        => EnsurePrivateRuleAsync(executablePath, [port]);

    public async Task<FirewallStatus> EnsurePrivateRuleAsync(string executablePath, IReadOnlyCollection<int> ports)
    {
        if (ports.Count == 0)
        {
            return new(
                FirewallRuleState.Unavailable,
                "No listener ports are configured for the sharing service.",
                false);
        }

        if (!OperatingSystem.IsWindows())
        {
            return Check(executablePath, ports);
        }

        try
        {
            var script = BuildRuleScript(NormalizePath(executablePath), ports);
            var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -NonInteractive -EncodedCommand {encoded}",
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            });

            if (process is null)
            {
                return new(FirewallRuleState.Unavailable, "Windows Firewall setup could not be started.", false);
            }

            await process.WaitForExitAsync().ConfigureAwait(false);
            if (process.ExitCode != 0)
            {
                return new(
                    FirewallRuleState.Unavailable,
                    "Windows denied firewall setup. Approve the administrator prompt or add the private rule manually.",
                    false);
            }

            return Check(executablePath, ports);
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            logger?.LogWarning(ex, "Windows Firewall setup was cancelled or failed");
            return new(
                FirewallRuleState.Unavailable,
                "Windows denied firewall setup. Approve the administrator prompt or add the private rule manually.",
                false);
        }
    }

    internal static string BuildRuleScript(string executablePath, IReadOnlyCollection<int> ports)
    {
        var safePath = executablePath.Replace("'", "''", StringComparison.Ordinal);
        var builder = new StringBuilder();
        builder.Append("$ErrorActionPreference='Stop'; ");
#pragma warning disable CA1305
        // Replace-or-add per port, and clear the legacy single-port rule so the
        // old port is not left open after the HTTPS listener exists.
        builder.Append($"netsh advfirewall firewall delete rule name='{RuleName}' | Out-Null; ");
        foreach (var port in ports.Distinct())
        {
            var safePort = port.ToString(CultureInfo.InvariantCulture);
            var ruleName = RuleNameFromPort(port);
            builder.Append($"netsh advfirewall firewall delete rule name='{ruleName}' | Out-Null; ");
            builder.Append(
                $"netsh advfirewall firewall add rule name='{ruleName}' dir=in action=allow "
                + $"protocol=TCP localport={safePort} profile=private program='{safePath}' enable=yes | Out-Null; ");
        }

        builder.Append("exit $LASTEXITCODE");
#pragma warning restore CA1305
        return builder.ToString();
    }

    internal static string RuleNameFromPort(int port) =>
        $"{RuleNamePrefix}{port.ToString(CultureInfo.InvariantCulture)}";

    private bool IsActivePrivateNetworkProfile()
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -NonInteractive -Command \"@("
                    + "Get-NetConnectionProfile | Where-Object { "
                    + "$_.NetworkCategory -eq 'Private' -and "
                    + "$_.IPv4Connectivity -ne 'NoTraffic' "
                    + "}).Count -gt 0\"",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                CreateNoWindow = true,
            });

            if (process is null || !process.WaitForExit(3000))
            {
                try
                {
                    process?.Kill(entireProcessTree: true);
                }
                catch
                {
                    // Best-effort timeout cleanup; the status remains unavailable.
                }

                return false;
            }

            var output = process.StandardOutput.ReadToEnd().Trim();
            return process.ExitCode == 0
                && output.Equals("True", StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            logger?.LogWarning(ex, "Unable to inspect the active Windows network profile");
            return false;
        }
    }

    private static bool Matches(dynamic rule, string expectedPath, int port)
    {
        var profileMask = Convert.ToInt32(rule.Profiles, CultureInfo.InvariantCulture);
        var localPorts = ((string?)rule.LocalPorts ?? string.Empty)
            .Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);

        return Convert.ToInt32(rule.Enabled, CultureInfo.InvariantCulture) != 0
            && Convert.ToInt32(rule.Direction, CultureInfo.InvariantCulture) == Inbound
            && Convert.ToInt32(rule.Action, CultureInfo.InvariantCulture) == Allow
            && Convert.ToInt32(rule.Protocol, CultureInfo.InvariantCulture) == Tcp
            && profileMask == PrivateProfile
            && localPorts.Any(value => value == port.ToString(CultureInfo.InvariantCulture))
            && string.Equals(NormalizePath((string?)rule.ApplicationName), expectedPath, StringComparison.OrdinalIgnoreCase);
    }

    private static string NormalizePath(string? path) =>
        string.IsNullOrWhiteSpace(path) ? string.Empty : Path.GetFullPath(path);

    private static void ReleaseCom(object value)
    {
        if (Marshal.IsComObject(value))
        {
            Marshal.FinalReleaseComObject(value);
        }
    }
}
