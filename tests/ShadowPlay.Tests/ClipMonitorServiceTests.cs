using Xunit;
using System.Diagnostics;
using ShadowPlay.Core.Clips;
using ShadowPlay.Core.Models;

namespace ShadowPlay.Tests;

/// <summary>
/// Integration-style tests for ClipMonitorService using real timers with very short
/// windows. Production defaults are 3s poll / 6s stability; tests use milliseconds.
/// </summary>
public sealed class ClipMonitorServiceTests : IDisposable
{
    private readonly TempFolder _folder = new();
    private readonly ClipCatalog _catalog = new();

    private static MonitorOptions Fast => new()
    {
        PollInterval = TimeSpan.FromMilliseconds(50),
        ReconcileInterval = TimeSpan.FromMilliseconds(400),
        DebounceDelay = TimeSpan.FromMilliseconds(30),
        StabilityWindow = TimeSpan.FromMilliseconds(250),
        MinObservations = 2,
    };

    [Fact]
    public async Task Existing_complete_files_are_detected_at_startup_including_subfolders()
    {
        _folder.CreateMp4("root_clip.mp4", 2048);
        _folder.CreateMp4(@"sub dir\nested_clip.mp4", 512);

        await using var monitor = new ClipMonitorService(() => _folder.Path, _catalog, TimeProvider.System, Fast);
        await monitor.StartAsync();
        try
        {
            var clips = await WaitForConditionAsync(
                () => _catalog.GetClips(),
                clips => clips.Count == 2);

            Assert.Contains(clips, c => c.FileName == "root_clip.mp4");
            Assert.Contains(clips, c => c.FileName == "nested_clip.mp4");
            Assert.All(clips, c => Assert.True(c.SizeBytes > 0));
        }
        finally
        {
            await monitor.StopAsync();
        }
    }

    [Fact]
    public async Task Growing_file_is_not_published_until_writing_stops()
    {
        await using var monitor = new ClipMonitorService(() => _folder.Path, _catalog, TimeProvider.System, Fast);
        await monitor.StartAsync();

        var path = System.IO.Path.Combine(_folder.Path, "growing.mp4");
        await using (var stream = new FileStream(path, FileMode.CreateNew))
        {
            for (var i = 0; i < 6; i++)
            {
                // Window is 250ms and we append every 60ms: it must never stabilize mid-write.
                await stream.WriteAsync(new byte[4096]);
                await stream.FlushAsync();

                Assert.DoesNotContain(_catalog.GetClips(), c => c.FileName == "growing.mp4");
                await Task.Delay(60);
            }
        }

        var entry = await WaitForConditionAsync(
            () => _catalog.GetClips().FirstOrDefault(c => c.FileName == "growing.mp4"),
            clip => clip is not null && clip.SizeBytes >= 24 * 1024);
        Assert.NotNull(entry);
    }

    [Fact]
    public async Task Deleted_files_leave_the_catalog_via_watcher_or_reconcile()
    {
        var path = _folder.CreateMp4("doomed.mp4");

        await using var monitor = new ClipMonitorService(() => _folder.Path, _catalog, TimeProvider.System, Fast);
        await monitor.StartAsync();
        try
        {
            await WaitForConditionAsync(
                () => _catalog.GetClips(),
                clips => clips.Any(c => c.FileName == "doomed.mp4"));

            File.Delete(path);

            await WaitForConditionAsync(
                () => _catalog.GetClips(),
                clips => clips.Count == 0);
        }
        finally
        {
            await monitor.StopAsync();
        }
    }

    [Fact]
    public async Task Renamed_files_keep_one_catalog_entry_under_the_new_name()
    {
        var oldPath = _folder.CreateMp4("before_rename.mp4");

        await using var monitor = new ClipMonitorService(() => _folder.Path, _catalog, TimeProvider.System, Fast);
        await monitor.StartAsync();
        try
        {
            await WaitForConditionAsync(
                () => _catalog.GetClips(),
                clips => clips.Any(c => c.FileName == "before_rename.mp4"));

            File.Move(oldPath, System.IO.Path.Combine(_folder.Path, "after_rename.mp4"));

            await WaitForConditionAsync(
                () => _catalog.GetClips(),
                clips => clips.Count == 1 && clips[0].FileName == "after_rename.mp4");
        }
        finally
        {
            await monitor.StopAsync();
        }
    }

    [Fact]
    public async Task Temp_recording_names_are_never_published()
    {
        _folder.CreateMp4("~temp_inprogress.tmp.mp4");
        _folder.CreateMp4("._temp_partial.mp4");
        _folder.CreateMp4("real.mp4");

        await using var monitor = new ClipMonitorService(() => _folder.Path, _catalog, TimeProvider.System, Fast);
        await monitor.StartAsync();
        try
        {
            var clips = await WaitForConditionAsync(
                () => _catalog.GetClips(),
                clips => clips.Any(c => c.FileName == "real.mp4"));
            Assert.Single(clips);
            Assert.Equal("real.mp4", clips[0].FileName);
        }
        finally
        {
            await monitor.StopAsync();
        }
    }

    [Fact]
    public async Task Startup_reconciliation_removes_entries_for_vanished_files()
    {
        // Seed the catalog as if a previous session had tracked two files.
        var keptPath = _folder.CreateMp4("kept.mp4", 100);
        var gonePath = _folder.CreateMp4("gone.mp4", 200);
        _catalog.AddOrUpdate(MakeEntry(keptPath));
        _catalog.AddOrUpdate(MakeEntry(gonePath));
        File.Delete(gonePath);

        await using var monitor = new ClipMonitorService(() => _folder.Path, _catalog, TimeProvider.System, Fast);
        await monitor.StartAsync();
        try
        {
            await WaitForConditionAsync(
                () => _catalog.GetClips(),
                clips => clips.Count == 1 && clips[0].FileName == "kept.mp4");
        }
        finally
        {
            await monitor.StopAsync();
        }
    }

    [Fact]
    public async Task Changed_file_size_republishes_with_updated_metadata()
    {
        var path = _folder.CreateMp4("resized.mp4", 100);

        await using var monitor = new ClipMonitorService(() => _folder.Path, _catalog, TimeProvider.System, Fast);
        await monitor.StartAsync();
        try
        {
            await WaitForConditionAsync(
                () => _catalog.GetClips(),
                clips => clips.Any());

            await File.WriteAllBytesAsync(path, new byte[900]);
            File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddSeconds(1));

            await WaitForConditionAsync(
                () => _catalog.GetClips().SingleOrDefault(c => c.FileName == "resized.mp4"),
                clip => clip is not null && clip.SizeBytes == 900);
        }
        finally
        {
            await monitor.StopAsync();
        }
    }

    [Fact]
    public async Task Unchanged_files_do_not_repeat_preview_processing()
    {
        _folder.CreateMp4("stable.mp4", 100);
        var preview = new CountingPreviewProvider();

        await using var monitor = new ClipMonitorService(
            () => _folder.Path,
            _catalog,
            TimeProvider.System,
            Fast,
            previewProvider: preview);
        await monitor.StartAsync();
        try
        {
            await WaitForConditionAsync(
                () => _catalog.GetClips().SingleOrDefault(),
                clip => clip is not null && clip.Duration == TimeSpan.FromSeconds(7));

            await Task.Delay(800);

            Assert.Equal(1, preview.DurationCalls);
        }
        finally
        {
            await monitor.StopAsync();
        }
    }

    [Fact]
    public async Task Stop_cancels_background_work_promptly_and_restart_works()
    {
        var monitor = new ClipMonitorService(() => _folder.Path, _catalog, TimeProvider.System, Fast);
        await monitor.StartAsync();

        var stopwatch = Stopwatch.StartNew();
        await monitor.StopAsync();
        stopwatch.Stop();

        Assert.False(monitor.IsRunning);
        Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(3), $"Stop took {stopwatch.Elapsed}");

        // Restarting on the same instance must work cleanly.
        await monitor.StartAsync();
        Assert.True(monitor.IsRunning);
        await monitor.StopAsync();
        await monitor.DisposeAsync();
    }

    [Fact]
    public async Task Missing_folder_is_reported_and_does_not_throw()
    {
        var missing = System.IO.Path.Combine(_folder.Path, "no_such_dir");
        string? unavailableReported = null;

        await using var monitor = new ClipMonitorService(
            () => missing,
            _catalog,
            TimeProvider.System,
            Fast);
        monitor.RootUnavailable += root => unavailableReported = root;

        await monitor.StartAsync(); // must not throw

        await WaitForConditionAsync(
            () => unavailableReported,
            reported => reported is not null);
        Assert.False(monitor.IsRunning);
    }

    private static ClipEntry MakeEntry(string fullPath) =>
        new(
            ClipIdCalculator.Calculate(fullPath),
            Path.GetFileName(fullPath),
            fullPath,
            new FileInfo(fullPath).Length,
            new DateTimeOffset(File.GetLastWriteTimeUtc(fullPath)));

    private sealed class CountingPreviewProvider : IClipPreviewProvider
    {
        public bool SupportsThumbnails => false;

        public int DurationCalls { get; private set; }

        public TimeSpan? GetDuration(string fullPath)
        {
            DurationCalls++;
            return TimeSpan.FromSeconds(7);
        }

        public byte[]? GetThumbnail(ClipEntry entry) => null;
    }

    private static async Task<T> WaitForConditionAsync<T>(Func<T> probe, Func<T, bool> condition)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
        while (DateTime.UtcNow < deadline)
        {
            var value = probe();
            if (condition(value))
            {
                return value;
            }

            await Task.Delay(50);
        }

        throw new TimeoutException($"Condition was not met within 10s (last value: {probe()}).");
    }

    public void Dispose() => _folder.Dispose();
}
