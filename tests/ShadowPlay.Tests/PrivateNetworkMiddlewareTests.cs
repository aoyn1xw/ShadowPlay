using System.Net;
using Microsoft.AspNetCore.Http;
using ShadowPlay.Api;
using Xunit;

namespace ShadowPlay.Tests;

public sealed class PrivateNetworkMiddlewareTests
{
    [Fact]
    public async Task Public_client_is_rejected_before_endpoint()
    {
        var called = false;
        var middleware = new PrivateNetworkMiddleware(_ =>
        {
            called = true;
            return Task.CompletedTask;
        }, enabled: true);
        var context = new DefaultHttpContext();
        context.Connection.RemoteIpAddress = IPAddress.Parse("203.0.113.9");

        await middleware.InvokeAsync(context);

        Assert.Equal(StatusCodes.Status403Forbidden, context.Response.StatusCode);
        Assert.False(called);
    }

    [Fact]
    public async Task Private_client_reaches_endpoint()
    {
        var called = false;
        var middleware = new PrivateNetworkMiddleware(_ =>
        {
            called = true;
            return Task.CompletedTask;
        }, enabled: true);
        var context = new DefaultHttpContext();
        context.Connection.RemoteIpAddress = IPAddress.Parse("192.168.0.42");

        await middleware.InvokeAsync(context);

        Assert.True(called);
        Assert.NotEqual(StatusCodes.Status403Forbidden, context.Response.StatusCode);
    }
}
