using Xunit;
using Microsoft.Extensions.Time.Testing;
using ShadowPlay.Core.Clips;

namespace ShadowPlay.Tests;

public class EventDebouncerTests
{
    [Fact]
    public async Task Burst_of_events_fires_once_after_quiet_period()
    {
        var time = new FakeTimeProvider();
        var fired = new List<string>();
        using var debouncer = new EventDebouncer(time, TimeSpan.FromMilliseconds(500), fired.Add);

        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "debounce_a.mp4");
        debouncer.Post(path);
        debouncer.Post(path);
        debouncer.Post(path);

        await Task.Delay(50); // allow timer plumbing if any real thread involved
        Assert.Empty(fired); // nothing before the delay elapses

        time.Advance(TimeSpan.FromMilliseconds(600));
        await Task.Delay(50);

        Assert.Single(fired);
    }

    [Fact]
    public async Task New_event_within_the_window_restarts_the_timer()
    {
        var time = new FakeTimeProvider();
        var fired = new List<string>();
        using var debouncer = new EventDebouncer(time, TimeSpan.FromMilliseconds(500), fired.Add);

        var pathA = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "debounce_b1.mp4");
        var pathB = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "debounce_b2.mp4");

        debouncer.Post(pathA);
        time.Advance(TimeSpan.FromMilliseconds(400));
        debouncer.Post(pathA); // restart

        time.Advance(TimeSpan.FromMilliseconds(400)); // 800ms since first post but only 400ms since last
        await Task.Delay(30);
        Assert.Empty(fired);

        time.Advance(TimeSpan.FromMilliseconds(200));
        await Task.Delay(30);
        Assert.Single(fired);

        // Different paths fire independently.
        debouncer.Post(pathB);
        time.Advance(TimeSpan.FromMilliseconds(600));
        await Task.Delay(30);
        Assert.Equal(2, fired.Count);
    }

    [Fact]
    public void Dispose_prevents_further_posts()
    {
        var time = new FakeTimeProvider();
        var debouncer = new EventDebouncer(time, TimeSpan.FromMilliseconds(10), _ => { });
        debouncer.Dispose();

        Assert.Throws<ObjectDisposedException>(() =>
            debouncer.Post(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "x.mp4")));
    }
}
