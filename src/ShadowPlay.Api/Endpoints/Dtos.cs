namespace ShadowPlay.Api.Endpoints;

/// <summary>API-safe clip metadata (camelCase JSON). No filesystem paths.</summary>
public sealed record ClipDto(string Id, string FileName, long SizeBytes, DateTimeOffset LastWriteTimeUtc);

public sealed record ServerDto(
    string ServerId,
    string ComputerName,
    int ProtocolVersion,
    DateTimeOffset StartedUtc,
    int ClipCount);

public sealed record PairExchangeRequest(string? PairingCode, string? DeviceName);

public sealed record PairExchangeResponse(string Token, string DeviceId, ServerDto Server);
