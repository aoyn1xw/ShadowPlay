namespace ShadowPlay.Core.Models;

/// <summary>
/// A clip as tracked in the in-memory catalog. <see cref="FullPath"/> is host-side
/// only and must never be serialized to API clients.
/// </summary>
public sealed record ClipEntry(
    string Id,
    string FileName,
    string FullPath,
    long SizeBytes,
    DateTimeOffset LastWriteTimeUtc)
{
    public ClipInfo ToInfo() => new(Id, FileName, SizeBytes, LastWriteTimeUtc);
}
