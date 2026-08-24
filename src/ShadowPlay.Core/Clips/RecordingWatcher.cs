namespace ShadowPlay.Core.Clips;

/// <summary>Raw filesystem event notifications, already normalized to full paths.</summary>
public sealed class RecordingWatcherHandlers
{
    public Action<string>? CreatedOrChanged { get; init; }

    public Action<string>? Deleted { get; init; }

    /// <summary>A renamed file: the old path vanished, the new path appeared.</summary>
    public Action<string, string>? Renamed { get; init; }

    public Action<Exception>? Error { get; init; }
}

/// <summary>
/// Thin wrapper around <see cref="FileSystemWatcher"/> with a larger buffer and
/// restart support. Events are forwarded as-is; debouncing happens upstream.
/// </summary>
public sealed class RecordingWatcher : IDisposable
{
    private readonly string _root;
    private readonly RecordingWatcherHandlers _handlers;
    private FileSystemWatcher? _watcher;

    public RecordingWatcher(string rootFolder, RecordingWatcherHandlers handlers)
    {
        _root = rootFolder;
        _handlers = handlers ?? throw new ArgumentNullException(nameof(handlers));
    }

    public bool IsRunning => _watcher?.EnableRaisingEvents == true;

    public void Start()
    {
        StopWatcher();

        var watcher = new FileSystemWatcher(_root)
        {
            IncludeSubdirectories = true,
            InternalBufferSize = 64 * 1024,
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size,
        };

        watcher.Created += OnCreatedOrChanged;
        watcher.Changed += OnCreatedOrChanged;
        watcher.Renamed += OnRenamed;
        watcher.Deleted += OnDeleted;
        watcher.Error += OnError;

        try
        {
            watcher.EnableRaisingEvents = true;
        }
        catch (Exception ex) when (ex is IOException or ArgumentException)
        {
            watcher.Dispose();
            throw;
        }

        _watcher = watcher;
    }

    private void OnCreatedOrChanged(object sender, FileSystemEventArgs e)
    {
        if (e.ChangeType is WatcherChangeTypes.Created or WatcherChangeTypes.Changed)
        {
            _handlers.CreatedOrChanged?.Invoke(e.FullPath);
        }
    }

    private void OnDeleted(object sender, FileSystemEventArgs e) =>
        _handlers.Deleted?.Invoke(e.FullPath);

    private void OnRenamed(object sender, RenamedEventArgs e) =>
        _handlers.Renamed?.Invoke(e.OldFullPath, e.FullPath);

    private void OnError(object sender, ErrorEventArgs e) =>
        _handlers.Error?.Invoke(e.GetException());

    private void StopWatcher()
    {
        if (_watcher is null)
        {
            return;
        }

        try
        {
            _watcher.EnableRaisingEvents = false;
            _watcher.Dispose();
        }
        catch (Exception ex) when (ex is ObjectDisposedException or IOException)
        {
            // Best effort during teardown/race with buffer overflow handling.
        }
        finally
        {
            _watcher = null;
        }
    }

    public void Dispose() => StopWatcher();
}
