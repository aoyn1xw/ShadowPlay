using Microsoft.AspNetCore.Http;
using ShadowPlay.Core.Networking;

namespace ShadowPlay.Api;

/// <summary>
/// Restricts the API to loopback and private-network clients so the service is not
/// reachable from arbitrary internet-exposed interfaces.
/// </summary>
public sealed class PrivateNetworkMiddleware
{
    private readonly RequestDelegate _next;
    private readonly bool _enabled;

    public PrivateNetworkMiddleware(RequestDelegate next, bool enabled)
    {
        _next = next;
        _enabled = enabled;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        if (_enabled && !LocalIpLocator.IsAllowedClientAddress(context.Connection.RemoteIpAddress))
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            await context.Response.WriteAsJsonAsync(new { error = "forbidden" }).ConfigureAwait(false);
            return;
        }

        await _next(context).ConfigureAwait(false);
    }
}
