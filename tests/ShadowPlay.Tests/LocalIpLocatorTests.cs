using Xunit;
using System.Net;
using ShadowPlay.Core.Networking;

namespace ShadowPlay.Tests;

public class LocalIpLocatorTests
{
    [Theory]
    [InlineData("127.0.0.1", true)]
    [InlineData("192.168.1.50", true)]
    [InlineData("10.0.0.7", true)]
    [InlineData("172.16.0.1", true)]
    [InlineData("172.31.255.255", true)]
    [InlineData("172.32.0.1", false)]
    [InlineData("169.254.10.5", true)]
    [InlineData("8.8.8.8", false)]
    [InlineData("203.0.113.9", false)]
    [InlineData("::1", true)]
    public void Private_and_loopback_clients_are_allowed(string address, bool expected)
    {
        Assert.Equal(expected, LocalIpLocator.IsAllowedClientAddress(IPAddress.Parse(address)));
    }

    [Fact]
    public void Null_address_is_rejected()
    {
        Assert.False(LocalIpLocator.IsAllowedClientAddress(null));
    }

    [Fact]
    public void Preferred_selection_orders_by_range()
    {
        var chosen = LocalIpLocator.SelectPreferred(
        [
            IPAddress.Parse("10.1.2.3"),
            IPAddress.Parse("192.168.7.7"),
            IPAddress.Parse("172.20.0.4"),
        ]);

        Assert.Equal(IPAddress.Parse("192.168.7.7"), chosen);
    }

    [Fact]
    public void Public_addresses_are_never_selected()
    {
        var chosen = LocalIpLocator.SelectPreferred([IPAddress.Parse("8.8.8.8")]);
        Assert.Null(chosen);
    }
}
