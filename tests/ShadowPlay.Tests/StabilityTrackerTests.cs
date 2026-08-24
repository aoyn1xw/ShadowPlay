using Xunit;
using Microsoft.Extensions.Time.Testing;
using ShadowPlay.Core.Clips;

namespace ShadowPlay.Tests;

public class StabilityTrackerTests
{
    private static readonly DateTimeOffset T0 = new(2026, 1, 1, 12, 0, 0, TimeSpan.Zero);

    private readonly MonitorOptions _options = new()
    {
        StabilityWindow = TimeSpan.FromSeconds(6),
        MinObservations = 2,
    };

    [Fact]
    public void Single_observation_is_never_ready()
    {
        var tracker = new StabilityTracker(_options);
        tracker.RegisterObservation(@"C:\clips\a.mp4", 100, T0, now: T0);

        Assert.Empty(tracker.GetReady(T0.AddSeconds(60)));
    }

    [Fact]
    public void Two_identical_observations_inside_the_window_are_not_ready()
    {
        var tracker = new StabilityTracker(_options);
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "stability_a.mp4");

        tracker.RegisterObservation(path, 100, T0, T0);
        tracker.RegisterObservation(path, 100, T0, T0.AddSeconds(2)); // only 2s span

        Assert.Empty(tracker.GetReady(T0.AddSeconds(10)));
    }

    [Fact]
    public void Two_observations_spanning_the_window_become_ready_once()
    {
        var tracker = new StabilityTracker(_options);
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "stability_b.mp4");

        tracker.RegisterObservation(path, 100, T0, T0);
        tracker.RegisterObservation(path, 100, T0, T0.AddSeconds(7));

        var ready = tracker.GetReady(T0.AddSeconds(7));
        Assert.Single(ready, p => p.Equals(path, StringComparison.OrdinalIgnoreCase));

        // Once published it must not be yielded again.
        tracker.MarkPublished(path);
        Assert.Empty(tracker.GetReady(T0.AddSeconds(8)));
    }

    [Fact]
    public void Size_change_resets_the_stability_window()
    {
        var tracker = new StabilityTracker(_options);
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "stability_c.mp4");

        tracker.RegisterObservation(path, 100, T0, T0);
        tracker.RegisterObservation(path, 200, T0.AddSeconds(1), T0.AddSeconds(7)); // grew

        // Only one observation since the change -> not ready even after a long wait.
        Assert.Empty(tracker.GetReady(T0.AddMinutes(5)));

        tracker.RegisterObservation(path, 200, T0.AddSeconds(1), T0.AddMinutes(5).AddSeconds(7));
        Assert.Single(tracker.GetReady(T0.AddMinutes(5).AddSeconds(7)));
    }

    [Fact]
    public void Mtime_change_resets_the_stability_window()
    {
        var tracker = new StabilityTracker(_options);
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "stability_d.mp4");

        tracker.RegisterObservation(path, 100, T0, T0);
        tracker.RegisterObservation(path, 100, T0.AddSeconds(3), T0.AddSeconds(7)); // mtime bumped

        Assert.Empty(tracker.GetReady(T0.AddHours(1)));
    }

    [Fact]
    public void Drop_removes_tracking()
    {
        var tracker = new StabilityTracker(_options);
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "stability_e.mp4");

        tracker.RegisterObservation(path, 100, T0, T0);
        tracker.RegisterObservation(path, 100, T0, T0.AddSeconds(7));
        tracker.Drop(path);

        Assert.False(tracker.IsTracked(path));
        Assert.Empty(tracker.GetReady(T0.AddSeconds(30)));
    }
}
