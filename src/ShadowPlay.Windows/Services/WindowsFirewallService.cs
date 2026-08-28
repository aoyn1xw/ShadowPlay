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
}

/// <summary>
/// Checks and explicitly provisions one inbound TCP rule for the current ShadowPlay
/// executable and port. The rule is private-profile-only; this service never enables
/// Windows Firewall or opens a public-profile port.
/// </summary>
public sealed class WindowsFirewallService(ILogger<WindowsFirewallService>? logger = null)
    : IWindowsFirewallService
{
    public const string RuleName = "ShadowPlay LAN API (Private)";

    private const int Inbound = 1;
    private const int Tcp = 6;
    private const int Allow = 1;
    private const int PrivateProfile = 2;

    public FirewallStatus Check(string executablePath, int port)
    {
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
                var foundNamedRule = false;
                var matchingRule = false;

                dynamic rules = policy.Rules;
                foreach (dynamic rule in rules)
                {
                    if (!string.Equals((string?)rule.Name, RuleName, StringComparison.Ordinal))
                    {
                        continue;
                    }

                    foundNamedRule = true;
                    if (Matches(rule, expectedPath, port))
                    {
                        matchingRule = true;
                        break;
                    }
                }

                if (matchingRule && privateActive)
                {
                    return new(
                        FirewallRuleState.Ready,
                        $"Private firewall rule is active for TCP {port}.",
                        true);
                }

                if (matchingRule)
                {
                    return new(
                        FirewallRuleState.BlockedByNetworkProfile,
                        "The rule is private-only, but the active Wi-Fi network is not marked Private.",
                        false);
                }

                return new(
                    foundNamedRule ? FirewallRuleState.Mismatched : FirewallRuleState.Missing,
                    foundNamedRule
                        ? "A ShadowPlay firewall rule exists, but it does not match this executable and port."
                        : "No private-only ShadowPlay firewall rule exists for this executable and port.",
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

    public async Task<FirewallStatus> EnsurePrivateRuleAsync(string executablePath, int port)
    {
        if (!OperatingSystem.IsWindows())
        {
            return Check(executablePath, port);
        }

        try
        {
            var script = BuildRuleScript(NormalizePath(executablePath), port);
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

            return Check(executablePath, port);
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

    internal static string BuildRuleScript(string executablePath, int port)
    {
        var safePath = executablePath.Replace("'", "''", StringComparison.Ordinal);
        var safePort = port.ToString(CultureInfo.InvariantCulture);
        return $"$ErrorActionPreference='Stop'; "
            + $"netsh advfirewall firewall delete rule name='{RuleName}' | Out-Null; "
            + $"netsh advfirewall firewall add rule name='{RuleName}' dir=in action=allow "
            + $"protocol=TCP localport={safePort} profile=private program='{safePath}' enable=yes | Out-Null; "
            + "exit $LASTEXITCODE";
    }

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
