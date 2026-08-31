using System.Net;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using ShadowPlay.Api.Endpoints;

namespace ShadowPlay.Api;

/// <summary>
/// Builds the self-hosted LAN API <see cref="WebApplication"/>. Structured so that
/// transport details (Kestrel vs test server, HTTP vs pinned HTTPS) are isolated here.
///
/// SECURITY: this MVP speaks plain HTTP on the LAN. Devices are authenticated via
/// bearer tokens, but traffic is NOT encrypted. Pinned local HTTPS can replace this
/// layer later without touching endpoint logic.
/// </summary>
public static class LanApiFactory
{
    public static WebApplication Build(LanApiOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        var builder = WebApplication.CreateBuilder(new WebApplicationOptions
        {
            ApplicationName = "ShadowPlay.Api",
            EnvironmentName = Environments.Production,
        });

        // We manage logging ourselves (file logger in the desktop app).
        builder.Logging.ClearProviders();
        builder.Logging.SetMinimumLevel(LogLevel.Information);

        options.ConfigureWebHost?.Invoke(builder.WebHost);
        if (options.ConfigureWebHost is null)
        {
            builder.WebHost.UseKestrel(kestrel =>
            {
                kestrel.Listen(IPAddress.Any, options.Port, listen => listen.Protocols = HttpProtocols.Http1);
                kestrel.AddServerHeader = false;
            });
        }

        var app = builder.Build();

        app.Use(async (context, next) =>
        {
            try
            {
                await next(context).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
            {
                // Client disconnected mid-download; nothing to do.
            }
            catch (Exception ex)
            {
                var logger = context.RequestServices.GetRequiredService<ILoggerFactory>()
                    .CreateLogger("ShadowPlay.Api");
                var requestMethod = context.Request.Method
                    .Replace("\r", "\\r", StringComparison.Ordinal)
                    .Replace("\n", "\\n", StringComparison.Ordinal);
                var requestPath = (context.Request.Path.Value ?? string.Empty)
                    .Replace("\r", "\\r", StringComparison.Ordinal)
                    .Replace("\n", "\\n", StringComparison.Ordinal);
                logger.LogError(ex, "Unhandled API error on {Method} {Path}", requestMethod, requestPath);

                if (!context.Response.HasStarted)
                {
                    context.Response.Clear();
                    context.Response.StatusCode = StatusCodes.Status500InternalServerError;
                    await context.Response.WriteAsJsonAsync(new { error = "internal_error" }).ConfigureAwait(false);
                }
            }
        });

        app.Use(async (context, next) =>
        {
            var isPairingDiagnosticPath = context.Request.Path.Equals(
                    $"{LanApiEndpoints.BasePath}/health",
                    StringComparison.OrdinalIgnoreCase)
                || context.Request.Path.Equals(
                    $"{LanApiEndpoints.BasePath}/pair/exchange",
                    StringComparison.OrdinalIgnoreCase);

            if (!isPairingDiagnosticPath)
            {
                await next(context).ConfigureAwait(false);
                return;
            }

            var logger = context.RequestServices.GetRequiredService<ILoggerFactory>()
                .CreateLogger("ShadowPlay.Api.Network");
            var requestMethod = context.Request.Method
                .Replace("\r", "\\r", StringComparison.Ordinal)
                .Replace("\n", "\\n", StringComparison.Ordinal);
            var requestPath = (context.Request.Path.Value ?? string.Empty)
                .Replace("\r", "\\r", StringComparison.Ordinal)
                .Replace("\n", "\\n", StringComparison.Ordinal);
            var remote = (context.Connection.RemoteIpAddress?.ToString() ?? "unknown")
                .Replace("\r", "\\r", StringComparison.Ordinal)
                .Replace("\n", "\\n", StringComparison.Ordinal);
            logger.LogInformation(
                "Incoming LAN request {Method} {Path} from {RemoteIp}",
                requestMethod,
                requestPath,
                remote);

            try
            {
                await next(context).ConfigureAwait(false);
            }
            finally
            {
                logger.LogInformation(
                    "Completed LAN request {Method} {Path} from {RemoteIp} with HTTP {StatusCode}",
                    requestMethod,
                    requestPath,
                    remote,
                    context.Response.StatusCode);
            }
        });

        app.UseMiddleware<PrivateNetworkMiddleware>(options.RestrictToPrivateNetworks);
        app.UseMiddleware<BearerAuthMiddleware>(options.Devices);

        app.MapLanApi(options);

        return app;
    }
}
