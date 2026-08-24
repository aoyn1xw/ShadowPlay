using System.Windows;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using ShadowPlay.Windows.Bootstrap;
using ShadowPlay.Windows.Services;
using ShadowPlay.Windows.Tray;
using ShadowPlay.Windows.ViewModels;
using ShadowPlay.Windows.Views;
using Application = System.Windows.Application;
using MessageBox = System.Windows.MessageBox;
using MessageBoxButton = System.Windows.MessageBoxButton;
using MessageBoxImage = System.Windows.MessageBoxImage;

namespace ShadowPlay.Windows;

public partial class App : Application
{
    private IHost? _host;
    private SingleInstanceGuard? _guard;
    private TrayIconService? _tray;
    private MainWindow? _mainWindow;

    /// <summary>True while the app is shutting down; windows may close for real then.</summary>
    public bool IsExiting { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        var cli = CliOptions.Parse(e.Args);

        if (cli.SmokeTest)
        {
            RunSmokeModeAsync(cli);
            return; // SmokeRunner calls Shutdown when done.
        }

        _guard = SingleInstanceGuard.TryAcquire();
        if (!_guard.Acquired)
        {
            MessageBox.Show(
                "ShadowPlay is already running. Look for its icon in the system tray.",
                "ShadowPlay",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            Shutdown();
            return;
        }

        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show($"Something went wrong: {args.Exception.Message}", "ShadowPlay",
                MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };

        _host = AppHostFactory.Build(cli);
        _host.Start();

        var controller = _host.Services.GetRequiredService<AppController>();

        _tray = _host.Services.GetRequiredService<TrayIconService>();
        _tray.ExitRequested = RequestExit;
        _tray.OpenRequested = OpenRequestedHandler;
        _tray.SettingsRequested = ShowSettingsWindow;
        _tray.Initialize();

        _ = InitializeControllerAsync(controller);

        _guard.ActivationRequested += () => Dispatcher.BeginInvoke(ShowMainWindow);
    }

    private async Task InitializeControllerAsync(AppController controller)
    {
        await controller.InitializeAsync();

        await Dispatcher.InvokeAsync(() =>
        {
            if (!controller.IsConfigured)
            {
                ShowSetupDialog();
            }
            else
            {
                // Normal operation: stay in the tray.
            }
        });
    }

    public void ShowSetupDialog()
    {
        var controller = _host!.Services.GetRequiredService<AppController>();
        var validator = _host.Services.GetRequiredService<Core.Validation.IFolderValidator>();
        var setupVm = new SetupViewModel(validator, controller.RecordingsFolder);
        var setupWindow = new SetupWindow(controller, setupVm)
        {
            Icon = Services.RuntimeIcon.CreateIconSource(),
        };
        setupWindow.ShowDialog();

        // After first-time setup the app lives in the tray.
        if (controller.IsConfigured)
        {
            _mainWindow = null;
        }
    }

    public void ShowSettingsWindow()
    {
        var run = () =>
        {
            // Only one settings dialog at a time.
            if (Application.Current?.Windows.OfType<SettingsWindow>().Any() == true)
            {
                return;
            }

            var controller = _host!.Services.GetRequiredService<AppController>();
            var validator = _host.Services.GetRequiredService<Core.Validation.IFolderValidator>();
            var window = new SettingsWindow(
                controller,
                new SettingsViewModel(controller, validator))
            {
                Icon = Services.RuntimeIcon.CreateIconSource(),
                Owner = _mainWindow is { IsVisible: true } ? _mainWindow : null,
            };
            window.ShowDialog();
        };

        if (Dispatcher.CheckAccess())
        {
            run();
        }
        else
        {
            Dispatcher.Invoke(run);
        }
    }

    private void OpenRequestedHandler() => Dispatcher.Invoke(ShowMainWindow);

    public void ShowMainWindow()
    {
        if (_mainWindow is null)
        {
            var vm = new MainViewModel(
                _host!.Services.GetRequiredService<AppController>(),
                openSettings: ShowSettingsWindow);

            _mainWindow = new MainWindow(this, vm)
            {
                Icon = Services.RuntimeIcon.CreateIconSource(),
            };
            _mainWindow.Show();
        }
        else
        {
            _mainWindow.Show();
            _mainWindow.WindowState = WindowState.Normal;
            _mainWindow.Activate();
        }
    }

    private void RequestExit()
    {
        IsExiting = true;

        try
        {
            var controller = _host?.Services.GetService<AppController>();
            controller?.DisposeAsync().AsTask().Wait(TimeSpan.FromSeconds(5));
        }
        catch
        {
            // Shut down regardless.
        }

        _tray?.Dispose();

        try
        {
            _host?.StopAsync(TimeSpan.FromSeconds(3)).Wait(TimeSpan.FromSeconds(4));
        }
        catch
        {
        }

        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        IsExiting = true;
        _tray?.Dispose();
        _host?.Dispose();
        _guard?.Dispose();
        base.OnExit(e);
    }

    private async void RunSmokeModeAsync(CliOptions cli)
    {
        var code = await SmokeRunner.RunAsync(cli);
        Shutdown(code);
    }
}
