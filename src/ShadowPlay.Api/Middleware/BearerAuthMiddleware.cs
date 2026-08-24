using Microsoft.AspNetCore.Http;
using ShadowPlay.Core.Devices;

namespace ShadowPlay.Api;

/// <summary>
/// Bearer-token authentication. Exempt paths (health, pair/exchange) are skipped.
/// Incoming tokens are hashed and compared against stored hashes; raw tokens are never logged.
/// </summary>
public sealed class BearerAuthMiddleware
{
    public static readonly IReadOnlySet<string> AnonymousPaths = new HashSet<string>(StringComparer.Ordinal)
    {
        "/api/v1/health",
        "/api/v1/pair/exchange",
    };

    private readonly RequestDelegate _next;
    private readonly IDeviceRegistry _devices;

    public BearerAuthMiddleware(RequestDelegate next, IDeviceRegistry devices)
    {
        _next = next;
        _devices = devices;
    }

    public async Task InvokeAsync(HttpContext context)
    {
        var path = context.Request.Path.Value?.TrimEnd('/').ToLowerInvariant();

        // Only API routes require authentication; anything else falls through (404).
        if (path is null || !path.StartsWith("/api/", StringComparison.Ordinal))
        {
            await _next(context).ConfigureAwait(false);
            return;
        }

        if (AnonymousPaths.Contains(path))
        {
            await _next(context).ConfigureAwait(false);
            return;
        }

        if (!TryExtractToken(context.Request, out var token))
        {
            await WriteUnauthorized(context).ConfigureAwait(false);
            return;
        }

        var device = _devices.ValidateToken(token!);
        if (device is null)
        {
            await WriteUnauthorized(context).ConfigureAwait(false);
            return;
        }

        context.Items[DeviceItemKey] = device;
        await _next(context).ConfigureAwait(false);
    }

    public const string DeviceItemKey = "ShadowPlay.Device";

    internal static bool TryExtractToken(HttpRequest request, out string? token)
    {
        token = null;
        var header = request.Headers.Authorization.ToString();
        if (string.IsNullOrWhiteSpace(header))
        {
            return false;
        }

        const string scheme = "Bearer ";
        if (!header.StartsWith(scheme, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        token = header[scheme.Length..].Trim();
        return token.Length > 0;
    }

    private static async Task WriteUnauthorized(HttpContext context)
    {
        context.Response.StatusCode = StatusCodes.Status401Unauthorized;
        context.Response.Headers.WWWAuthenticate = "Bearer";
        await context.Response.WriteAsJsonAsync(new { error = "unauthorized" }).ConfigureAwait(false);
    }
}
