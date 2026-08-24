using System.Collections.Concurrent;

namespace ShadowPlay.Core.Clips;

/// <summary>
/// Tracks candidate recordings until their size and last-write time have remained
/// unchanged across at least <see cref="MonitorOptions.MinObservations"/> checks that
/// span at least <see cref="MonitorOptions.StabilityWindow"/> of wall time between the
/// FIRST and LAST confirming check. Any change restarts the window, so partially
/// written files are never published. Time is supplied by callers (testable).
/// </summary>
public sealed class StabilityTracker
{
    private readonly ConcurrentDictionary<string, Candidate> _candidates = new(StringComparer.OrdinalIgnoreCase);
    private readonly MonitorOptions _options;

    public StabilityTracker(MonitorOptions? options = null)
    {
        _options = options ?? new MonitorOptions();
    }

    private sealed record Candidate(
        long SizeBytes,
        DateTimeOffset LastWriteTimeUtc,
        DateTimeOffset FirstSeenUtc,
        DateTimeOffset LastObservedUtc,
        int Observations,
        bool Published);

    /// <summary>Records an observation of the current file state.</summary>
    public void RegisterObservation(string fullPath, long sizeBytes, DateTimeOffset lastWriteTimeUtc, DateTimeOffset now)
    {
        var key = Normalize(fullPath);
        _candidates.AddOrUpdate(
            key,
            _ => new Candidate(sizeBytes, lastWriteTimeUtc, now, now, 1, false),
            (_, existing) =>
            {
                if (existing.SizeBytes == sizeBytes && existing.LastWriteTimeUtc == lastWriteTimeUtc)
                {
                    return existing with { Observations = existing.Observations + 1, LastObservedUtc = now };
                }

                // File changed since the last observation: restart the stability window.
                return new Candidate(sizeBytes, lastWriteTimeUtc, now, now, 1, false);
            });
    }

    /// <summary>Candidate paths meeting the stability criteria that are not yet published.</summary>
    public IReadOnlyList<string> GetReady(DateTimeOffset now)
    {
        List<string>? ready = null;
        foreach (var (key, candidate) in _candidates)
        {
            if (candidate.Published
                || candidate.Observations < _options.MinObservations
                || candidate.LastObservedUtc - candidate.FirstSeenUtc < _options.StabilityWindow)
            {
                continue;
            }

            ready ??= [];
            ready.Add(key);
        }

        return ready ?? [];
    }

    /// <summary>All tracked paths that have not been published yet (for periodic re-observation).</summary>
    public IReadOnlyList<string> GetUnpublished()
    {
        List<string>? paths = null;
        foreach (var (key, candidate) in _candidates)
        {
            if (candidate.Published)
            {
                continue;
            }

            paths ??= [];
            paths.Add(key);
        }

        return paths ?? [];
    }

    public void MarkPublished(string fullPath)
    {
        var key = Normalize(fullPath);
        if (_candidates.TryGetValue(key, out var candidate))
        {
            _candidates[key] = candidate with { Published = true };
        }
    }

    public void Drop(string fullPath) => _candidates.TryRemove(Normalize(fullPath), out _);

    public bool IsTracked(string fullPath) => _candidates.ContainsKey(Normalize(fullPath));

    private static string Normalize(string path) => Path.GetFullPath(path).ToLowerInvariant();
}
