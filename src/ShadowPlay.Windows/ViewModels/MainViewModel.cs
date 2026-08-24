using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using ShadowPlay.Core.Models;
using ShadowPlay.Core.Networking;
using ShadowPlay.Windows.Services;
using Brush = System.Windows.Media.Brush;
using Brushes = System.Windows.Media.Brushes;
using Application = System.Windows.Application;

namespace ShadowPlay.Windows.ViewModels;

public sealed record ClipRow(string Id, string FileName, string SizeDisplay, string ModifiedDisplay);

public sealed record DeviceRow(string DeviceId, string Name, string PairedDisplay);

/// <summary>Main window state: status, address, QR, clips and paired devices.</summary>
public sealed class MainViewModel : ObservableObject
{
    private readonly AppController _controller;
    private readonly Action _openSettings;
    private readonly Dispatcher _dispatcher;
    private ImageSource? _qrImage;
    private string _statusText = "Starting...";
    private string? _statusDetail;
    private Brush _statusBrush = Brushes.Gray;
    private string _addressText = "-";
    private bool _isRunning;
    private string _pairingHint = "";
    private DispatcherTimer? _countdownTimer;

    public MainViewModel(AppController controller, Action openSettings)
    {
        _controller = controller ?? throw new ArgumentNullException(nameof(controller));
        _openSettings = openSettings ?? throw new ArgumentNullException(nameof(openSettings));
        _dispatcher = Application.Current.Dispatcher;

        _controller.StateChanged += () => _dispatcher.BeginInvoke(RefreshAll);

        RefreshAll();
    }

    public ObservableCollection<ClipRow> Clips { get; } = [];

    public ObservableCollection<DeviceRow> Devices { get; } = [];

    public string StatusText { get => _statusText; private set => SetProperty(ref _statusText, value); }

    public string? StatusDetail { get => _statusDetail; private set => SetProperty(ref _statusDetail, value); }

    public Brush StatusBrush { get => _statusBrush; private set => SetProperty(ref _statusBrush, value); }

    public string AddressText { get => _addressText; private set => SetProperty(ref _addressText, value); }

    public bool IsRunning { get => _isRunning; private set => SetProperty(ref _isRunning, value); }

    private string _pauseResumeLabel = "Pause sharing";

    public string PauseResumeLabel
    {
        get => _pauseResumeLabel;
        private set => SetProperty(ref _pauseResumeLabel, value);
    }

    public ImageSource? QrImage { get => _qrImage; private set => SetProperty(ref _qrImage, value); }

    public string PairingHint { get => _pairingHint; private set => SetProperty(ref _pairingHint, value); }

    public ICommand RegeneratePairingCommand => new RelayCommand(
        () =>
        {
            var payload = _controller.BuildQrPayload(regenerate: true);
            ApplyQr(payload);
            StartCountdown();
        },
        () => _controller.IsSharingRunning || _controller.Status.State == SharingState.Paused);

    public ICommand ToggleSharingCommand => new RelayCommand(async () => await _controller.ToggleSharingAsync());

    public ICommand ChangeFolderCommand => new RelayCommand(_openSettings);

    public ICommand OpenFolderCommand => new RelayCommand(() => _controller.OpenRecordingsFolderInExplorer());

    public ICommand RevokeDeviceCommand => new RelayCommand<string>(deviceId =>
    {
        if (deviceId is not null)
        {
            _controller.RevokeDevice(deviceId);
            RefreshDevices();
        }
    });

    /// <summary>Refreshes everything from the controller. Must run on the UI thread.</summary>
    public void RefreshAll()
    {
        var status = _controller.Status;
        (StatusText, StatusBrush) = status.State switch
        {
            SharingState.Running => ($"Sharing on port {status.Port}", Brushes.Green),
            SharingState.Starting => ("Starting sharing...", Brushes.DarkOrange),
            SharingState.Paused => ("Sharing paused", Brushes.DarkOrange),
            SharingState.NotConfigured => ("Choose a recordings folder to begin", Brushes.Gray),
            SharingState.Error => ("Problem detected", Brushes.Red),
            _ => ("Unknown", Brushes.Gray),
        };

        StatusDetail = status.Detail ?? _controller.RecordingsFolder;
        IsRunning = status.State == SharingState.Running;
        PauseResumeLabel = IsRunning ? "Pause sharing" : "Start sharing";

        AddressText = IsRunning
            ? $"{LocalIpLocator.FindBestIpv4()?.ToString() ?? "localhost"}:{status.Port}"
            : "-";

        if (IsRunning && QrImage is null)
        {
            var payload = _controller.BuildQrPayload(regenerate: false);
            ApplyQr(payload);
            StartCountdown();
        }
        else if (status.State is SharingState.Paused or SharingState.NotConfigured or SharingState.Error)
        {
            PairingHint = "Start sharing to generate a pairing code.";
        }

        RefreshClips();
        RefreshDevices();

        OnPropertyChanged(nameof(RecordingsFolder));
    }

    public string? RecordingsFolder => _controller.RecordingsFolder;

    private void ApplyQr(string? payload)
    {
        QrImage = Services.QrCodeService.CreatePng(payload ?? "");
        PairingHint = payload is null ? "" : "Scan with the ShadowPlay phone app to pair.";
    }

    private void StartCountdown()
    {
        _countdownTimer?.Stop();
        _countdownTimer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromSeconds(15),
        };
        _countdownTimer.Tick += (_, _) =>
        {
            var expires = _controller.PairingExpiresAt;
            if (expires is null)
            {
                PairingHint = "Pairing code expired. Click 'New pairing code'.";
                _countdownTimer?.Stop();
                return;
            }

            var remaining = expires.Value - DateTimeOffset.UtcNow;
            PairingHint = remaining > TimeSpan.Zero
                ? $"Pairing code expires in {Math.Ceiling(remaining.TotalMinutes)} min. Scan with the phone app."
                : "Pairing code expired. Click 'New pairing code'.";
        };
        _countdownTimer.Start();
    }

    private void RefreshClips()
    {
        Clips.Clear();
        foreach (var clip in _controller.CatalogSnapshot())
        {
            Clips.Add(new ClipRow(
                clip.Id,
                clip.FileName,
                $"{clip.SizeBytes / (1024d * 1024d):F1} MB",
                clip.LastWriteTimeUtc.ToLocalTime().ToString("yyyy-MM-dd HH:mm", System.Globalization.CultureInfo.InvariantCulture)));
        }
    }

    private void RefreshDevices()
    {
        Devices.Clear();
        foreach (var device in _controller.PairedDevices)
        {
            Devices.Add(new DeviceRow(
                device.DeviceId,
                device.Name,
                $"paired {device.CreatedAtUtc.ToLocalTime():yyyy-MM-dd}"));
        }
    }
}
