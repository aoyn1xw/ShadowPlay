using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Routing;
using ShadowPlay.Api.Endpoints;
using ShadowPlay.Core.Clips;
using ShadowPlay.Core.Models;
using ShadowPlay.Core.Networking;
using ShadowPlay.Core.Pairing;

namespace ShadowPlay.Api;

/// <summary>Maps all versioned LAN endpoints.</summary>
public static class LanApiEndpoints
{
    public const string BasePath = "/api/v1";

    public static IEndpointRouteBuilder MapLanApi(this IEndpointRouteBuilder app, LanApiOptions options)
    {
        var api = app.MapGroup(BasePath);

        // ---- Anonymous -------------------------------------------------------

        api.MapGet("/health", () => Results.Json(new
        {
            status = "ok",
            serverId = options.ServerInfo.ServerId,
            protocolVersion = QrPayload.CurrentProtocolVersion,
            timeUtc = DateTimeOffset.UtcNow,
        }));

        api.MapPost("/pair/exchange", async Task<IResult> (
                [FromBody] PairExchangeRequest? request,
                CancellationToken ct) =>
            {
                if (request is null
                    || string.IsNullOrWhiteSpace(request.PairingCode)
                    || request.PairingCode.Length > 32)
                {
                    return Results.BadRequest(new { error = "invalid_request" });
                }

                var deviceName = string.IsNullOrWhiteSpace(request.DeviceName)
                    ? "Unnamed device"
                    : request.DeviceName.Trim();

                if (deviceName.Length > 64)
                {
                    deviceName = deviceName[..64];
                }

                // Small fixed delay blunts brute-force attempts against pairing codes.
                await Task.Delay(300, ct).ConfigureAwait(false);

                var result = options.Pairing.Exchange(request.PairingCode, deviceName);
                if (!result.Success)
                {
                    return Results.Conflict(new { error = "pairing_code_invalid_or_expired" });
                }

                return Results.Ok(new PairExchangeResponse(
                    result.BearerToken!,
                    result.Device!.DeviceId,
                    new ServerDto(
                        options.ServerInfo.ServerId,
                        options.ServerInfo.ComputerName,
                        QrPayload.CurrentProtocolVersion,
                        options.ServerInfo.StartedUtc,
                        options.Catalog.GetClips().Count)));
            })
            .WithMetadata(new RequestSizeLimitAttribute(4096));

        // ---- Authenticated (middleware enforces bearer tokens) ---------------

        api.MapGet("/server", () => Results.Ok(new ServerDto(
            options.ServerInfo.ServerId,
            options.ServerInfo.ComputerName,
            QrPayload.CurrentProtocolVersion,
            options.ServerInfo.StartedUtc,
            options.Catalog.GetClips().Count)));

        api.MapGet("/clips", () =>
        {
            var clips = options.Catalog.GetClips();
            return Results.Ok(clips.Select(c => c.ToInfo()).Select(ToDto));
        });

        api.MapGet("/clips/{id}", (string id) =>
        {
            if (!IsValidClipId(id))
            {
                return Results.NotFound(new { error = "clip_not_found" });
            }

            return options.Catalog.Find(id) is { } entry
                ? Results.Ok(ToDto(entry.ToInfo()))
                : Results.NotFound(new { error = "clip_not_found" });
        });

        api.MapGet("/clips/{id}/download", (string id) =>
        {
            if (!IsValidClipId(id))
            {
                return Results.NotFound(new { error = "clip_not_found" });
            }

            var entry = options.Catalog.Find(id);
            if (entry is null)
            {
                return Results.NotFound(new { error = "clip_not_found" });
            }

            var file = new FileInfo(entry.FullPath);
            if (!file.Exists || file.Length <= 0)
            {
                return Results.NotFound(new { error = "clip_no_longer_available" });
            }

            // Streams from disk with HTTP range/resume support; never loads into memory.
            return Results.File(
                entry.FullPath,
                contentType: "video/mp4",
                fileDownloadName: SafeFileName.For(entry.FileName),
                lastModified: entry.LastWriteTimeUtc,
                enableRangeProcessing: true);
        });

        return app;
    }

    private static ClipDto ToDto(ClipInfo info) => new(info.Id, info.FileName, info.SizeBytes, info.LastWriteTimeUtc);

    /// <summary>
    /// Clip IDs are 64 hex characters. Anything else (including path-like input)
    /// is rejected before it can ever reach a filesystem lookup.
    /// </summary>
    internal static bool IsValidClipId(string id) =>
        id.Length == 64 && id.All(char.IsAsciiHexDigit);
}
