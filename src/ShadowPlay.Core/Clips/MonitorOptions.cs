namespace ShadowPlay.Core.Clips;

/// <summary>Tuning knobs for the recording monitor.</summary>
public sealed class MonitorOptions
{
    /// <summary>How often pending candidates are re-checked and the queue drained.</summary>
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(3);

    /// <summary>Full rescan cadence; recovers events the watcher missed.</summary>
    public TimeSpan ReconcileInterval { get; init; } = TimeSpan.FromSeconds(60);

    /// <summary>Quiet period that collapses duplicate watcher events.</summary>
    public TimeSpan DebounceDelay { get; init; } = TimeSpan.FromMilliseconds(750);

    /// <summary>Minimum span between first and last confirming observation.</summary>
    public TimeSpan StabilityWindow { get; init; } = TimeSpan.FromSeconds(6);

    /// <summary>Minimum number of identical observations (>= 2 checks required).</summary>
    public int MinObservations { get; init; } = 2;
}
