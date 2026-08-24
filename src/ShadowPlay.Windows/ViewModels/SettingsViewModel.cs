using System.Windows;
using System.Windows.Input;
using ShadowPlay.Core.Validation;
using ShadowPlay.Windows.Services;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;

namespace ShadowPlay.Windows.ViewModels;

/// <summary>
/// Backing state for the small settings dialog opened from the tray:
/// watched folder, network port and the sharing switch.
/// </summary>
public sealed class SettingsViewModel : ObservableObject
{
    private readonly IFolderValidator _validator;
    private string _folderPath;
    private string _portText;
    private bool _sharingEnabled;
    private string? _message;
    private Brush _messageBrush = Brushes.Gray;

    public SettingsViewModel(AppController controller, IFolderValidator validator)
    {
        ArgumentNullException.ThrowIfNull(controller);
        _validator = validator ?? throw new ArgumentNullException(nameof(validator));
        _folderPath = controller.RecordingsFolder ?? "";
        _portText = controller.ConfiguredPort.ToString(System.Globalization.CultureInfo.InvariantCulture);
        _sharingEnabled = controller.SharingEnabledSetting;
        ValidateSilently();
    }

    public string FolderPath
    {
        get => _folderPath;
        set
        {
            if (SetProperty(ref _folderPath, value))
            {
                ValidateSilently();
            }
        }
    }

    public string PortText
    {
        get => _portText;
        set
        {
            if (SetProperty(ref _portText, value))
            {
                ValidateSilently();
            }
        }
    }

    public bool SharingEnabled
    {
        get => _sharingEnabled;
        set => SetProperty(ref _sharingEnabled, value);
    }

    public string? Message { get => _message; private set => SetProperty(ref _message, value); }

    public Brush MessageBrush { get => _messageBrush; private set => SetProperty(ref _messageBrush, value); }

    public bool CanSave => FolderOk && PortOk;

    private bool FolderOk { get; set; }

    private bool PortOk => int.TryParse(PortText?.Trim(), out var p) && p is >= 1 and <= 65535;

    public ICommand BrowseCommand => new RelayCommand(() =>
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            ShowNewFolderButton = true,
            UseDescriptionForTitle = true,
            Description = "Select the folder where your game recordings are saved",
        };

        if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
        {
            FolderPath = dialog.SelectedPath;
        }
    });

    /// <summary>Applies everything through the controller. Returns false with a message on failure.</summary>
    public async Task<bool> SaveAsync(AppController controller)
    {
        var folderResult = _validator.Validate(FolderPath);
        if (!folderResult.IsValid)
        {
            ShowError(folderResult.Error!);
            return false;
        }

        if (!int.TryParse(PortText?.Trim(), out var port) || port is < 1 or > 65535)
        {
            ShowError("Port must be a number between 1 and 65535.");
            return false;
        }

        var applied = await controller.ApplySettingsAsync(FolderPath, port, SharingEnabled);
        if (!applied)
        {
            ShowError(controller.Status.Detail ?? "The settings could not be applied.");
            return false;
        }

        return true;
    }

    private void ValidateSilently()
    {
        FolderOk = _validator.Validate(FolderPath).IsValid && FolderPath.Trim().Length > 0;

        Message = !FolderOk
            ? "Choose a folder that exists and is readable."
            : !PortOk
                ? "Port must be between 1 and 65535."
                : "All good. Saving restarts sharing with the new settings.";
        MessageBrush = FolderOk && PortOk ? Brushes.Green : Brushes.DarkOrange;
        OnPropertyChanged(nameof(CanSave));
    }

    private void ShowError(string text)
    {
        Message = text;
        MessageBrush = Brushes.Red;
    }
}
