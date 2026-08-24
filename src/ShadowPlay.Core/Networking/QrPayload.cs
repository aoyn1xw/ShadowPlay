using System.Text.Json.Serialization;

namespace ShadowPlay.Core.Networking;

/// <summary>
/// Versioned payload encoded into the pairing QR code.
/// Bump <see cref="ProtocolVersion"/> when the shape changes so old clients fail cleanly.
/// </summary>
public sealed record QrPayload
{
    [JsonPropertyName("v")]
    public int ProtocolVersion { get; init; } = CurrentProtocolVersion;

    [JsonPropertyName("serverId")]
    public string ServerId { get; init; } = string.Empty;

    [JsonPropertyName("computerName")]
    public string ComputerName { get; init; } = string.Empty;

    [JsonPropertyName("lanAddress")]
    public string LanAddress { get; init; } = string.Empty;

    [JsonPropertyName("port")]
    public int Port { get; init; }

    [JsonPropertyName("pairingCode")]
    public string PairingCode { get; init; } = string.Empty;

    public const int CurrentProtocolVersion = 1;

    private static readonly System.Text.Json.JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase,
    };

    public string ToJson() => System.Text.Json.JsonSerializer.Serialize(this, JsonOptions);
}
