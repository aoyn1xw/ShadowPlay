using System.Collections.Concurrent;
using ShadowPlay.Core.Models;

namespace ShadowPlay.Core.Clips;

/// <summary>Read-only view of the clip catalog.</summary>
public interface IClipCatalog
{
    /// <summary>All known clips, newest first.</summary>
    IReadOnlyList<ClipEntry> GetClips();

    ClipEntry? Find(string clipId);

    event Action? Changed;
}

/// <summary>Mutation surface used by the monitoring pipeline only.</summary>
public interface IClipStore
{
    void AddOrUpdate(ClipEntry entry);

    bool RemoveByPath(string fullPath);

    void ReplaceAll(IEnumerable<ClipEntry> entries);

    ClipEntry? FindByPath(string fullPath);

    /// <summary>Point-in-time copy of all entries (maintenance/reconciliation).</summary>
    IReadOnlyList<ClipEntry> Snapshot();
}

/// <summary>
/// Thread-safe in-memory catalog. Keys are stable opaque IDs derived from the full path.
/// </summary>
public sealed class ClipCatalog : IClipCatalog, IClipStore
{
    private readonly ConcurrentDictionary<string, ClipEntry> _clips = new();
    private Action? _changed;

    public event Action? Changed
    {
        add => _changed += value;
        remove => _changed -= value;
    }

    public IReadOnlyList<ClipEntry> GetClips() =>
        _clips.Values
            .OrderByDescending(c => c.LastWriteTimeUtc)
            .ThenBy(c => c.Id, StringComparer.Ordinal)
            .ToArray();

    public ClipEntry? Find(string clipId) =>
        _clips.TryGetValue(clipId, out var entry) ? entry : null;

    public ClipEntry? FindByPath(string fullPath)
    {
        var id = ClipIdCalculator.Calculate(fullPath);
        return Find(id);
    }

    public IReadOnlyList<ClipEntry> Snapshot() => _clips.Values.ToArray();

    public void AddOrUpdate(ClipEntry entry)
    {
        var existing = _clips.GetValueOrDefault(entry.Id);
        if (existing is not null
            && existing.SizeBytes == entry.SizeBytes
            && existing.LastWriteTimeUtc == entry.LastWriteTimeUtc
            && string.Equals(existing.FullPath, entry.FullPath, StringComparison.OrdinalIgnoreCase))
        {
            return; // No change, don't spam events.
        }

        _clips[entry.Id] = entry;
        RaiseChanged();
    }

    public bool RemoveByPath(string fullPath)
    {
        var id = ClipIdCalculator.Calculate(fullPath);
        if (_clips.TryRemove(id, out _))
        {
            RaiseChanged();
            return true;
        }

        return false;
    }

    public void ReplaceAll(IEnumerable<ClipEntry> entries)
    {
        _clips.Clear();
        foreach (var entry in entries)
        {
            _clips[entry.Id] = entry;
        }

        RaiseChanged();
    }

    private void RaiseChanged()
    {
        try
        {
            _changed?.Invoke();
        }
        catch
        {
            // Subscribers must not break the monitor.
        }
    }
}
