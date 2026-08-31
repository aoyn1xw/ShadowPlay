namespace ShadowPlay.Api.Endpoints;

/// <summary>API-safe clip metadata (camelCase JSON). No filesystem paths.</summary>
public sealed record ClipDto(
    string Id,
    string FileName,
    long SizeBytes,
    DateTimeOffset LastWriteTimeUtc,
    long? DurationMilliseconds,
    string? ThumbnailUrl);

public sealed record ServerDto(
    string ServerId,
    string ComputerName,
    int ProtocolVersion,
    DateTimeOffset StartedUtc,
    int ClipCount,
    string ServerVersion,
    int ApiVersion,
    IReadOnlyList<string> Capabilities);

public sealed record PairExchangeRequest(string? PairingCode, string? DeviceName);

public sealed record PairExchangeResponse(string Token, string DeviceId, ServerDto Server);
