using System.Collections.Concurrent;

namespace ShadowPlay.Core.Clips;

/// <summary>
/// Coalesces bursts of filesystem events for the same path into a single callback
/// after a quiet period. Uses <see cref="TimeProvider"/> so tests can advance virtual time.
/// </summary>
public sealed class EventDebouncer : IDisposable
{
    private readonly TimeProvider _timeProvider;
    private readonly TimeSpan _delay;
    private readonly Action<string> _sink;
    private readonly ConcurrentDictionary<string, ITimer> _timers = new(StringComparer.OrdinalIgnoreCase);
    private bool _disposed;

    public EventDebouncer(TimeProvider timeProvider, TimeSpan delay, Action<string> sink)
    {
        _timeProvider = timeProvider ?? throw new ArgumentNullException(nameof(timeProvider));
        _delay = delay <= TimeSpan.Zero ? TimeSpan.FromMilliseconds(500) : delay;
        _sink = sink ?? throw new ArgumentNullException(nameof(sink));
    }

    /// <summary>Schedules (or re-schedules) a debounced notification for the path.</summary>
    public void Post(string fullPath)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        var key = Path.GetFullPath(fullPath).ToLowerInvariant();

        while (true)
        {
            if (_timers.TryGetValue(key, out var existing))
            {
                var replacement = CreateTimer(key);
                if (_timers.TryUpdate(key, replacement, existing))
                {
                    existing.Dispose();
                    return;
                }

                replacement.Dispose();
            }
            else
            {
                var created = CreateTimer(key);
                if (_timers.TryAdd(key, created))
                {
                    return;
                }

                created.Dispose();
            }
        }
    }

    private ITimer CreateTimer(string key)
    {
        return _timeProvider.CreateTimer(
            _ => Fire(key),
            null,
            _delay,
            Timeout.InfiniteTimeSpan);
    }

    private void Fire(string key)
    {
        if (_timers.TryRemove(key, out var timer))
        {
            try
            {
                _sink(key);
            }
            catch
            {
                // Never let a subscriber kill the timer thread.
            }
            finally
            {
                timer.Dispose();
            }
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        foreach (var timer in _timers.Values)
        {
            timer.Dispose();
        }

        _timers.Clear();
    }
}
