using ShadowPlay.Core.Models;

namespace ShadowPlay.Core.Settings;

public interface ISettingsStore
{
    AppSettingsData Load();

    void Save(AppSettingsData data);
}
