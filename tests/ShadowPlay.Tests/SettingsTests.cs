using Xunit;
using ShadowPlay.Core.Models;
using ShadowPlay.Core.Settings;

namespace ShadowPlay.Tests;

public class SettingsTests : IDisposable
{
    private readonly TempFolder _folder = new();

    [Fact]
    public void Missing_file_yields_defaults_with_new_server_id()
    {
        var store = new JsonSettingsStore(_folder.Path);
        var data = store.Load();

        Assert.Null(data.RecordingsFolder);
        Assert.True(data.SharingEnabled);
        Assert.Equal(AppSettingsData.DefaultPort, data.Port);
        Assert.Matches("^[0-9a-f]{32}$", data.ServerId);
    }

    [Fact]
    public void Save_then_load_roundtrips()
    {
        var store = new JsonSettingsStore(_folder.Path);
        var data = new AppSettingsData
        {
            RecordingsFolder = @"C:\Videos\Captures",
            Port = 5555,
            SharingEnabled = false,
            ServerId = "fixed-server-id",
            Devices =
            [
                new PairedDeviceInfo("dev1", "iPhone", "AABB", new DateTimeOffset(2026, 2, 3, 4, 5, 6, TimeSpan.Zero)),
            ],
        };

        store.Save(data);
        var loaded = store.Load();

        Assert.Equal(@"C:\Videos\Captures", loaded.RecordingsFolder);
        Assert.Equal(5555, loaded.Port);
        Assert.False(loaded.SharingEnabled);
        Assert.Single(loaded.Devices);
        Assert.Equal("iPhone", loaded.Devices[0].Name);
        Assert.Equal("AABB", loaded.Devices[0].TokenHash);
    }

    [Fact]
    public void Corrupt_file_is_quarantined_and_defaults_returned()
    {
        Directory.CreateDirectory(_folder.Path);
        File.WriteAllText(System.IO.Path.Combine(_folder.Path, "settings.json"), "{ this is not json");

        var service = new SettingsService(new JsonSettingsStore(_folder.Path));

        Assert.True(service.Current.SharingEnabled);
        // Saving again must produce valid JSON going forward.
        service.Update(_ => { });
        var reloaded = new SettingsService(new JsonSettingsStore(_folder.Path));
        Assert.NotNull(reloaded.Current.ServerId);
    }

    [Fact]
    public void Update_persists_atomically_and_is_visible_to_new_readers()
    {
        var service = new SettingsService(new JsonSettingsStore(_folder.Path));

        service.Update(d => d.RecordingsFolder = @"D:\clips");
        service.Update(d => d.Port = 6000);

        var fresh = new JsonSettingsStore(_folder.Path).Load();
        Assert.Equal(@"D:\clips", fresh.RecordingsFolder);
        Assert.Equal(6000, fresh.Port);

        // No temp file left behind.
        Assert.False(File.Exists(System.IO.Path.Combine(_folder.Path, "settings.json.tmp")));
    }

    public void Dispose() => _folder.Dispose();
}
