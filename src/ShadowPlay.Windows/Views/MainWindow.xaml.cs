using System.ComponentModel;
using System.Windows;
using Microsoft.Extensions.DependencyInjection;
using ShadowPlay.Windows.Services;
using ShadowPlay.Windows.ViewModels;

namespace ShadowPlay.Windows.Views;

public partial class MainWindow : Window
{
    private readonly App _app;

    public MainWindow(App app, MainViewModel viewModel)
    {
        InitializeComponent();
        _app = app;
        DataContext = viewModel;
    }

    /// <summary>Closing hides to tray; only explicit Exit terminates the process.</summary>
    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_app.IsExiting)
        {
            e.Cancel = true;
            Hide();
            return;
        }

        base.OnClosing(e);
    }
}
