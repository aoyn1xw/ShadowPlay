using System.Text.Json;
using ShadowPlay.Core.Models;

namespace ShadowPlay.Core.Settings;

/// <summary>
/// Thread-safe facade over the persisted settings. Mutations go through
/// <see cref="Update"/> which applies, saves atomically and then swaps the in-memory copy.
/// </summary>
public interface ISettingsService
{
    /// <summary>The current settings snapshot (read-only usage).</summary>
    AppSettingsData Current { get; }

    void Update(Action<AppSettingsData> mutate);

    /// <summary>Replaces the entire data set (e.g. after loading or CLI overrides).</summary>
    void Replace(AppSettingsData data);

    bool Save();
}

/// <summary>File-backed implementation rooted at a directory such as %LocalAppData%\ShadowPlay.</summary>
public sealed class JsonSettingsStore : ISettingsStore
{
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private readonly string _filePath;
    private readonly object _sync = new();

    public JsonSettingsStore(string baseDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(baseDirectory);
        _filePath = Path.Combine(baseDirectory, "settings.json");
    }

    public string FilePath => _filePath;

    public AppSettingsData Load()
    {
        lock (_sync)
        {
            if (!File.Exists(_filePath))
            {
                return new AppSettingsData();
            }

            try
            {
                var json = File.ReadAllText(_filePath);
                return JsonSerializer.Deserialize<AppSettingsData>(json, SerializerOptions) ?? new AppSettingsData();
            }
            catch (Exception ex) when (ex is JsonException or IOException)
            {
                QuarantineCorruptFile();
                return new AppSettingsData();
            }
        }
    }

    public void Save(AppSettingsData data)
    {
        lock (_sync)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_filePath)!);
            var tempPath = _filePath + ".tmp";

            using (var stream = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, data, SerializerOptions);
            }

            // Atomic replace so a crash never leaves a half-written settings file.
            File.Move(tempPath, _filePath, overwrite: true);
        }
    }

    private void QuarantineCorruptFile()
    {
        try
        {
            var backup = _filePath + ".corrupt";
            File.Move(_filePath, backup, overwrite: true);
        }
        catch (IOException)
        {
        }
    }
}

/// <summary>In-memory service that keeps <see cref="ISettingsStore"/> and consumers consistent.</summary>
public sealed class SettingsService : ISettingsService
{
    private readonly ISettingsStore _store;
    private readonly object _sync = new();
    private AppSettingsData _current;

    public SettingsService(ISettingsStore store)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _current = store.Load();
    }

    public AppSettingsData Current
    {
        get
        {
            lock (_sync)
            {
                return Clone(_current);
            }
        }
    }

    public void Update(Action<AppSettingsData> mutate)
    {
        ArgumentNullException.ThrowIfNull(mutate);
        lock (_sync)
        {
            mutate(_current);
            SaveCore();
        }
    }

    public void Replace(AppSettingsData data)
    {
        ArgumentNullException.ThrowIfNull(data);
        lock (_sync)
        {
            _current = Clone(data);
            SaveCore();
        }
    }

    public bool Save()
    {
        lock (_sync)
        {
            return SaveCore();
        }
    }

    private bool SaveCore()
    {
        try
        {
            _store.Save(Clone(_current));
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static AppSettingsData Clone(AppSettingsData data) =>
        JsonSerializer.Deserialize<AppSettingsData>(JsonSerializer.Serialize(data)) ?? new AppSettingsData();
}
