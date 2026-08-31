namespace ShadowPlay.Core.Models;

/// <summary>
/// Public, API-safe description of a detected recording. Never contains filesystem paths.
/// </summary>
public sealed record ClipInfo(
    string Id,
    string FileName,
    long SizeBytes,
    DateTimeOffset LastWriteTimeUtc,
    TimeSpan? Duration = null);
