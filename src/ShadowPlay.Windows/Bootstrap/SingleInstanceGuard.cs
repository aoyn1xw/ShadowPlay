namespace ShadowPlay.Windows.Bootstrap;

/// <summary>
/// Prevents multiple app instances via a named mutex and lets a second instance
/// ask the first one to show its window through a named event.
/// </summary>
public sealed class SingleInstanceGuard : IDisposable
{
    private const string MutexName = @"Local\ShadowPlay.SingleInstance.9f2c1a";
    private const string ActivateEventName = @"Local\ShadowPlay.Activate.9f2c1a";

    private readonly Mutex? _mutex;
    private readonly EventWaitHandle? _activateHandle;
    private Thread? _listenerThread;

    private SingleInstanceGuard(Mutex? mutex, EventWaitHandle? activateHandle)
    {
        _mutex = mutex;
        _activateHandle = activateHandle;
    }

    /// <summary>True when this process owns the single-instance slot.</summary>
    public bool Acquired { get; private set; }

    public event Action? ActivationRequested;

    public static SingleInstanceGuard TryAcquire()
    {
        var mutex = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
        if (!createdNew)
        {
            // Another instance is running: poke it so it shows its window.
            SignalExistingInstance();
            mutex.Dispose();
            return new SingleInstanceGuard(null, null) { Acquired = false };
        }

        var activate = new EventWaitHandle(false, EventResetMode.AutoReset, ActivateEventName);
        var guard = new SingleInstanceGuard(mutex, activate) { Acquired = true };
        guard.StartActivationListener();
        return guard;
    }

    /// <summary>Signals the already-running instance to show its window.</summary>
    public static void SignalExistingInstance()
    {
        try
        {
            if (EventWaitHandle.TryOpenExisting(ActivateEventName, out var existing))
            {
                existing.Set();
                existing.Dispose();
            }
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or WaitHandleCannotBeOpenedException or ObjectDisposedException)
        {
        }
    }

    private void StartActivationListener()
    {
        _listenerThread = new Thread(() =>
        {
            try
            {
                while (_activateHandle!.WaitOne())
                {
                    ActivationRequested?.Invoke();
                }
            }
            catch (Exception ex) when (ex is AbandonedMutexException or ObjectDisposedException)
            {
            }
        })
        {
            IsBackground = true,
            Name = "ShadowPlay.ActivationListener",
        };
        _listenerThread.Start();
    }

    public void Dispose()
    {
        Acquired = false;

        try
        {
            _activateHandle?.Set(); // unblock listener thread
            _activateHandle?.Dispose();
        }
        catch (ObjectDisposedException)
        {
        }

        if (_mutex is not null)
        {
            try
            {
                if (_mutex.WaitOne(0))
                {
                    _mutex.ReleaseMutex();
                }
            }
            catch (AbandonedMutexException)
            {
            }

            _mutex.Dispose();
        }
    }
}
