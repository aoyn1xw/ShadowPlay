using System.ComponentModel;
using System.Windows;
using ShadowPlay.Windows.Services;
using ShadowPlay.Windows.ViewModels;

namespace ShadowPlay.Windows.Views;

/// <summary>
/// Small settings dialog (opened from the tray or the main window):
/// change the watched folder, network port and sharing switch.
/// Saving applies changes immediately through the AppController.
/// </summary>
public partial class SettingsWindow : Window
{
    private readonly AppController _controller;
    private bool _saved;

    public SettingsWindow(AppController controller, SettingsViewModel viewModel)
    {
        InitializeComponent();
        _controller = controller;
        DataContext = viewModel;
    }

    public SettingsViewModel ViewModel => (SettingsViewModel)DataContext;

    private async void OnSaveClick(object sender, RoutedEventArgs e)
    {
        var button = (System.Windows.Controls.Button)sender;
        button.IsEnabled = false;
        try
        {
            if (await ViewModel.SaveAsync(_controller))
            {
                _saved = true;
                DialogResult = true;
            }
        }
        finally
        {
            button.IsEnabled = true;
        }
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // Mark not-success so callers can distinguish saved vs cancelled if needed.
        if (!_saved)
        {
            DialogResult ??= false;
        }

        base.OnClosing(e);
    }
}
