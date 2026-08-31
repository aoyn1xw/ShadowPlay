using System.Collections.Concurrent;
using Microsoft.Extensions.Logging;
using ShadowPlay.Core.Models;

namespace ShadowPlay.Core.Clips;

/// <summary>
/// Orchestrates clip detection: startup scan, debounced watcher events,
/// stability gating, read-probing and periodic reconciliation with the filesystem.
/// Strictly read-only with respect to user recordings.
/// </summary>
public sealed class ClipMonitorService : IAsyncDisposable
{
    private readonly Func<string?> _rootFolderProvider;
    private readonly IClipStore _store;
    private readonly TimeProvider _timeProvider;
    private readonly MonitorOptions _options;
    private readonly IClipPreviewProvider? _previewProvider;
    private readonly ILogger? _logger;

    private readonly ConcurrentQueue<string> _pendingPaths = new();
    private readonly SemaphoreSlim _startStop = new(1, 1);

    private CancellationTokenSource? _cts;
    private RecordingWatcher? _watcher;
    private EventDebouncer? _debouncer;
    private List<Task> _loops = [];
    private StabilityTracker _tracker = new();
    private string? _activeRoot;

    public ClipMonitorService(
        Func<string?> rootFolderProvider,
        IClipStore store,
        TimeProvider timeProvider,
        MonitorOptions? options = null,
        ILogger? logger = null,
        IClipPreviewProvider? previewProvider = null)
    {
        _rootFolderProvider = rootFolderProvider ?? throw new ArgumentNullException(nameof(rootFolderProvider));
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _timeProvider = timeProvider ?? throw new ArgumentNullException(nameof(timeProvider));
        _options = options ?? new MonitorOptions();
        _logger = logger;
        _previewProvider = previewProvider;
        _tracker = new StabilityTracker(_options);
    }

    /// <summary>Raised when the recordings folder cannot be accessed (missing, denied, locked).</summary>
    public event Action<string>? RootUnavailable;

    /// <summary>Raised after the folder became accessible again following an outage.</summary>
    public event Action<string>? RootRecovered;

    public bool IsRunning { get; private set; }

    /// <summary>Starts monitoring. Safe to call multiple times (idempotent).</summary>
    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        await _startStop.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (IsRunning)
            {
                return;
            }

            var root = RequireRoot();
            if (root is null)
            {
                return;
            }

            _cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            var ct = _cts.Token;

            _debouncer = new EventDebouncer(_timeProvider, _options.DebounceDelay, EnqueueCandidate);
            _tracker = new StabilityTracker(_options);

            await ScanAndReconcileAsync(root, initial: true, ct).ConfigureAwait(false);
            StartWatcher(root);

            _loops =
            [
                Task.Run(() => PollLoopAsync(ct), CancellationToken.None),
                Task.Run(() => ReconcileLoopAsync(ct), CancellationToken.None),
            ];

            IsRunning = true;
            _logger?.LogInformation("Recording monitor started for the selected folder");
        }
        finally
        {
            _startStop.Release();
        }
    }

    /// <summary>Stops all background work cleanly, honouring cancellation.</summary>
    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        await _startStop.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!IsRunning && _cts is null)
            {
                return;
            }

            if (_cts is not null)
            {
                await _cts.CancelAsync().ConfigureAwait(false);
            }

            try
            {
                await Task.WhenAll(_loops).WaitAsync(TimeSpan.FromSeconds(5), cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                _logger?.LogWarning("Monitor loops did not stop within the grace period");
            }
            catch (OperationCanceledException)
            {
                // Caller gave up waiting; proceed with teardown.
            }

            _watcher?.Dispose();
            _watcher = null;
            _debouncer?.Dispose();
            _debouncer = null;
            _cts?.Dispose();
            _cts = null;
            _loops.Clear();
            IsRunning = false;
            _logger?.LogInformation("Recording monitor stopped");
        }
        finally
        {
            _startStop.Release();
        }
    }

    private string? RequireRoot()
    {
        var root = _rootFolderProvider();
        if (string.IsNullOrWhiteSpace(root) || !Directory.Exists(root))
        {
            _logger?.LogWarning("Recordings folder is not set or does not exist; monitor idle");
            RootUnavailable?.Invoke(root ?? string.Empty);
            return null;
        }

        return Path.GetFullPath(root);
    }

    private void StartWatcher(string root)
    {
        _watcher = new RecordingWatcher(root, new RecordingWatcherHandlers
        {
            CreatedOrChanged = path =>
            {
                if (IsRelevantPath(path))
                {
                    _debouncer?.Post(path);
                }
            },
            Deleted = path => RemoveFromCatalog(path),
            Renamed = (oldPath, newPath) =>
            {
                RemoveFromCatalog(oldPath);
                if (IsRelevantPath(newPath))
                {
                    _debouncer?.Post(newPath);
                }
            },
            Error = ex =>
            {
                _logger?.LogWarning(ex, "File watcher error; periodic reconciliation will recover missed events");
                RestartWatcherSoon(root);
            },
        });

        try
        {
            _watcher.Start();
        }
        catch (Exception ex) when (ex is IOException or ArgumentException)
        {
            _logger?.LogWarning(ex, "Could not start the file watcher; relying on reconciliation");
            _watcher.Dispose();
            _watcher = null;
        }
    }

    private void RestartWatcherSoon(string root)
    {
        // Recreate on a background thread with a small delay to survive transient failures.
        Task.Run(async () =>
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(2), GetToken()).ConfigureAwait(false);
                if (!Directory.Exists(root))
                {
                    return;
                }

                _watcher?.Dispose();
                StartWatcher(root);
                _logger?.LogInformation("File watcher restarted");
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception ex)
            {
                _logger?.LogDebug(ex, "Watcher restart failed");
            }
        }, CancellationToken.None);
    }

    private CancellationToken GetToken() => _cts?.Token ?? new CancellationToken(true);

    private static bool IsRelevantPath(string path) =>
        !RecordingScanner.IsTempRecordingName(path)
        && path.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase);

    private void EnqueueCandidate(string normalizedFullPath)
    {
        // Debouncer hands back a lower-cased full path; keep original casing from disk.
        _pendingPaths.Enqueue(normalizedFullPath);
    }

    private async Task PollLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var now = _timeProvider.GetUtcNow();

                // 1. Drain freshly signalled paths (watcher events, scans).
                while (_pendingPaths.TryDequeue(out var queued))
                {
                    ct.ThrowIfCancellationRequested();
                    ObservePath(queued, now);
                }

                // 2. Re-observe everything still pending so stability windows can elapse
                //    even when the filesystem goes quiet after a single event.
                foreach (var tracked in _tracker.GetUnpublished())
                {
                    ct.ThrowIfCancellationRequested();
                    ObservePath(tracked, now);
                }

                PublishReadyClips();

                await DelaySafe(_options.PollInterval, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                _logger?.LogDebug(ex, "Poll loop iteration failed");
                await DelaySafe(TimeSpan.FromSeconds(1), ct).ConfigureAwait(false);
            }
        }
    }

    private void ObservePath(string fullPath, DateTimeOffset now)
    {
        FileInfo info;
        try
        {
            info = new FileInfo(fullPath);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return;
        }

        if (!info.Exists || RecordingScanner.IsTempRecordingName(info.Name))
        {
            RemoveFromCatalog(fullPath);
            _tracker.Drop(fullPath);
            return;
        }

        _tracker.RegisterObservation(info.FullName, info.Length, new DateTimeOffset(info.LastWriteTimeUtc), now);
    }

    private void PublishReadyClips()
    {
        var now = _timeProvider.GetUtcNow();

        foreach (var path in _tracker.GetReady(now))
        {
            if (!FileReadProbe.CanOpenForRead(path))
            {
                continue; // Still being written or locked; retry next poll.
            }

            FileInfo info;
            try
            {
                info = new FileInfo(path);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                continue;
            }

            if (!info.Exists)
            {
                _tracker.Drop(path);
                continue;
            }

            var entry = new ClipEntry(
                ClipIdCalculator.Calculate(info.FullName),
                info.Name,
                info.FullName,
                info.Length,
                new DateTimeOffset(info.LastWriteTimeUtc),
                _previewProvider?.GetDuration(info.FullName));

            _store.AddOrUpdate(entry);
            _tracker.MarkPublished(path);
            _logger?.LogDebug("Clip available: {FileName} ({SizeBytes} bytes)", entry.FileName, entry.SizeBytes);
        }
    }

    private async Task ReconcileLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await DelaySafe(_options.ReconcileInterval, ct).ConfigureAwait(false);
                var root = _rootFolderProvider();
                if (!string.IsNullOrWhiteSpace(root) && Directory.Exists(root))
                {
                    var wasUnavailable = _activeRoot is null;
                    await ScanAndReconcileAsync(Path.GetFullPath(root), initial: false, ct).ConfigureAwait(false);
                    if (wasUnavailable)
                    {
                        RootRecovered?.Invoke(root);
                    }
                }
                else
                {
                    if (_activeRoot is not null)
                    {
                        _activeRoot = null;
                        _logger?.LogWarning("Recordings folder is currently unavailable");
                        RootUnavailable?.Invoke(root ?? string.Empty);
                    }
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                _logger?.LogDebug(ex, "Reconcile loop iteration failed");
            }
        }
    }

    /// <summary>
    /// Full scan of the folder tree. Existing catalog entries are refreshed or removed;
    /// new/changed files are fed through the stability tracker instead of being published blindly.
    /// </summary>
    private async Task ScanAndReconcileAsync(string root, bool initial, CancellationToken ct)
    {
        await Task.Yield(); // Ensure async semantics even for fast scans.

        var scanned = RecordingScanner.Scan(root, ct);
        _activeRoot = root;

        var scannedIds = new HashSet<string>(scanned.Count, StringComparer.Ordinal);

        foreach (var (fullPath, sizeBytes, lastWriteUtc) in scanned)
        {
            var id = ClipIdCalculator.Calculate(fullPath);
            scannedIds.Add(id);

            var existing = _store.FindByPath(fullPath);
            if (existing is not null
                && existing.SizeBytes == sizeBytes
                && existing.LastWriteTimeUtc == lastWriteUtc)
            {
                continue; // Unchanged since we last saw it.
            }

            // New or changed file: require stability before (re-)publishing.
            if (initial || !_tracker.IsTracked(fullPath))
            {
                _tracker.RegisterObservation(fullPath, sizeBytes, lastWriteUtc, _timeProvider.GetUtcNow());
                _pendingPaths.Enqueue(fullPath);
            }
        }

        // Remove catalog entries whose files have vanished.
        foreach (var entry in _store.Snapshot())
        {
            if (!scannedIds.Contains(entry.Id))
            {
                RemoveFromCatalog(entry.FullPath);
                _tracker.Drop(entry.FullPath);
            }
        }
    }

    private void RemoveFromCatalog(string fullPath)
    {
        if (_store.RemoveByPath(fullPath))
        {
            _logger?.LogDebug("Removed missing recording from catalog");
        }
    }

    private static async Task DelaySafe(TimeSpan delay, CancellationToken ct)
    {
        try
        {
            await Task.Delay(delay, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _startStop.Dispose();
    }
}
