using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace ShadowPlay.Core.Networking;

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

    /// <summary>Finds the preferred IPv4 across all live, non-virtual interfaces.</summary>
    public static IPAddress? FindBestIpv4()
    {
        var candidates = new List<IPAddress>();

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

                foreach (var unicast in nic.GetIPProperties().UnicastAddresses)
                {
                    var addr = unicast.Address;
                    if (addr.AddressFamily == AddressFamily.InterNetwork && !addr.Equals(IPAddress.Loopback))
                    {
                        candidates.Add(addr);
                    }
                }
            }
        }
        catch (NetworkInformationException)
        {
            return null;
        }

        return SelectPreferred(candidates);
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
