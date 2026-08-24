using System.Windows;
using System.Windows.Input;
using ShadowPlay.Core.Validation;
using ShadowPlay.Windows.Services;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;

namespace ShadowPlay.Windows.ViewModels;

/// <summary>First-run setup: choose and validate the recordings folder.</summary>
public sealed class SetupViewModel : ObservableObject
{
    private readonly IFolderValidator _validator;
    private string _folderPath = "";
    private string? _message;
    private Brush _messageBrush = Brushes.Gray;

    public SetupViewModel(IFolderValidator validator, string? initialFolder)
    {
        _validator = validator ?? throw new ArgumentNullException(nameof(validator));
        _folderPath = initialFolder ?? "";
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

    public string? Message { get => _message; private set => SetProperty(ref _message, value); }

    public Brush MessageBrush { get => _messageBrush; private set => SetProperty(ref _messageBrush, value); }

    public bool IsValid { get; private set; }

    public ICommand BrowseCommand => new RelayCommand(() =>
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            ShowNewFolderButton = true,
            UseDescriptionForTitle = true,
            Description = "Select the folder where your game recordings are saved",
        };

        var result = dialog.ShowDialog();
        if (result == System.Windows.Forms.DialogResult.OK)
        {
            FolderPath = dialog.SelectedPath;
        }
    });

    public event Action? Confirmed;

    public ICommand ConfirmCommand => new RelayCommand(async () => await ConfirmAsync());

    public async Task<bool> ConfirmAsync()
    {
        var result = _validator.Validate(FolderPath);
        if (!result.IsValid)
        {
            IsValid = false;
            Message = result.Error;
            MessageBrush = Brushes.Red;
            return false;
        }

        // Persisted by App after dialog closes (controller.SelectFolderAsync).
        IsValid = true;
        Confirmed?.Invoke();
        await Task.CompletedTask;
        return true;
    }

    private void ValidateSilently()
    {
        var result = _validator.Validate(FolderPath);
        IsValid = result.IsValid && FolderPath.Length > 0;
        Message = result.IsValid
            ? "Folder looks good."
            : result.Error;
        MessageBrush = result.IsValid ? Brushes.Green : Brushes.DarkOrange;
    }
}
