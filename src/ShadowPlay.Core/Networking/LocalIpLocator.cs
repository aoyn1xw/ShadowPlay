using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace ShadowPlay.Core.Networking;

public sealed record LanEndpoint(string InterfaceName, IPAddress Address, bool HasDefaultGateway);

/// <summary>
/// Picks the best LAN IPv4 address for QR/API display and classifies
/// private-network addresses used by the API's access guard.
/// </summary>
public static class LocalIpLocator
{
    /// <summary>True if the address is loopback, an RFC 1918 private range, link-local, or IPv6 ULA/loopback.</summary>
    public static bool IsAllowedClientAddress(IPAddress? address)
    {
        if (address is null)
        {
            return false;
        }

        if (address.IsIPv6LinkLocal || address.IsIPv6SiteLocal || address.IsIPv6UniqueLocal)
        {
            return true;
        }

        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            return address.Equals(IPAddress.IPv6Loopback);
        }

        var ip = address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;

        if (ip.Equals(IPAddress.Loopback))
        {
            return true;
        }

        var bytes = ip.GetAddressBytes();
        if (bytes.Length != 4)
        {
            return false;
        }

        return bytes[0] switch
        {
            10 => true,
            172 => bytes[1] is >= 16 and <= 31,
            192 => bytes[1] == 168,
            169 => bytes[1] == 254, // link-local; useful for direct Wi-Fi hotspots
            127 => true,
            _ => false,
        };
    }

    /// <summary>Deterministic preference: 192.168.x > 172.16-31.x > 10.x > link-local.</summary>
    public static IPAddress? SelectPreferred(IEnumerable<IPAddress> candidates)
    {
        IPAddress? best = null;
        var bestRank = int.MaxValue;

        foreach (var candidate in candidates)
        {
            var rank = Rank(candidate);
            if (rank < bestRank)
            {
                best = candidate;
                bestRank = rank;
            }
        }

        return best;
    }

    /// <summary>Finds the preferred IPv4 across all live, non-loopback/tunnel interfaces.</summary>
    public static IPAddress? FindBestIpv4()
        => FindBestEndpoint()?.Address;

    /// <summary>
    /// Finds the preferred IPv4 address and retains the interface metadata used for
    /// diagnostics. Interfaces with an active IPv4 gateway win over isolated virtual
    /// adapters before the private-range preference is applied.
    /// </summary>
    public static LanEndpoint? FindBestEndpoint()
    {
        var candidates = new List<LanEndpoint>();

        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up)
                {
                    continue;
                }

                if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel)
                {
                    continue;
                }

                var hasDefaultGateway = nic.GetIPProperties().GatewayAddresses
                    .Any(gateway => gateway.Address.AddressFamily == AddressFamily.InterNetwork);

                foreach (var unicast in nic.GetIPProperties().UnicastAddresses)
                {
                    var addr = unicast.Address;
                    if (addr.AddressFamily == AddressFamily.InterNetwork && !addr.Equals(IPAddress.Loopback))
                    {
                        candidates.Add(new LanEndpoint(nic.Name, addr, hasDefaultGateway));
                    }
                }
            }
        }
        catch (NetworkInformationException)
        {
            return null;
        }

        return SelectPreferredEndpoint(candidates);
    }

    /// <summary>Deterministically selects a reachable-looking LAN endpoint.</summary>
    public static LanEndpoint? SelectPreferredEndpoint(IEnumerable<LanEndpoint> candidates)
    {
        LanEndpoint? best = null;
        var bestRank = int.MaxValue;
        foreach (var candidate in candidates)
        {
            var rank = CandidateRank(candidate);
            if (rank < bestRank || (rank == bestRank && string.CompareOrdinal(candidate.InterfaceName, best?.InterfaceName) < 0))
            {
                best = candidate;
                bestRank = rank;
            }
        }

        return best;
    }

    private static int CandidateRank(LanEndpoint candidate)
    {
        var rangeRank = Rank(candidate.Address);
        if (rangeRank == int.MaxValue)
        {
            return int.MaxValue;
        }

        // A gateway-backed interface is the one most likely to reach the phone.
        return (candidate.HasDefaultGateway ? 0 : 1) * 100 + rangeRank;
    }

    private static int Rank(IPAddress address)
    {
        var ip = address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;
        if (!IsAllowedClientAddress(ip) || ip.Equals(IPAddress.Loopback))
        {
            return int.MaxValue;
        }

        var first = ip.GetAddressBytes()[0];
        return first switch
        {
            192 => 0,
            172 => 1,
            10 => 2,
            169 => 3,
            _ => int.MaxValue,
        };
    }
}
