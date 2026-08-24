using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Windows.Threading;
using ShadowPlay.Windows.Services;
using Forms = System.Windows.Forms;
using Application = System.Windows.Application;

namespace ShadowPlay.Windows.Tray;

/// <summary>
/// System tray presence built on WinForms NotifyIcon (per product requirement).
/// Rebuilds its context menu whenever the controller state changes.
/// </summary>
public sealed class TrayIconService : IDisposable
{
    private readonly AppController _controller;
    private readonly Icon _icon;
    private readonly Forms.NotifyIcon _notifyIcon;

    public TrayIconService(AppController controller)
    {
        _controller = controller ?? throw new ArgumentNullException(nameof(controller));

        _icon = CreateTrayIcon();
        _notifyIcon = new Forms.NotifyIcon
        {
            Text = "ShadowPlay",
            Visible = false,
        };
        _notifyIcon.DoubleClick += (_, _) => OpenRequested?.Invoke();
    }

    /// <summary>Purple rounded square with a white play glyph, drawn via GDI+.</summary>
    private static Icon CreateTrayIcon()
    {
        using var bitmap = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;

            using var background = new GraphicsPath();
            background.AddArc(0, 0, 14, 14, 180, 90);
            background.AddArc(18, 0, 14, 14, 270, 90);
            background.AddArc(18, 18, 14, 14, 0, 90);
            background.AddArc(0, 18, 14, 14, 90, 90);
            background.CloseFigure();

            using var gradient = new LinearGradientBrush(
                new Rectangle(0, 0, 32, 32),
                Color.FromArgb(0x7C, 0x4D, 0xFF),
                Color.FromArgb(0x45, 0x27, 0xA0),
                90f);
            g.FillPath(gradient, background);

            PointF[] triangle =
            [
                new(11f, 8f),
                new(24f, 16f),
                new(11f, 24f),
            ];
            using var white = new SolidBrush(Color.White);
            g.FillPolygon(white, triangle);
        }

        return Icon.FromHandle(bitmap.GetHicon());
    }

    /// <summary>Raised when the user wants the main window (double-click / Open).</summary>
    public Action? OpenRequested { get; set; }

    /// <summary>Raised from the tray's "Settings" item.</summary>
    public Action? SettingsRequested { get; set; }

    public void Initialize()
    {
        _notifyIcon.Icon = _icon;
        _notifyIcon.Visible = true;
        RebuildMenu();
        _controller.StateChanged += RebuildMenu;
    }

    private void RebuildMenu()
    {
        if (Application.Current?.Dispatcher.CheckAccess() != true)
        {
            Application.Current?.Dispatcher.BeginInvoke(RebuildMenu);
            return;
        }

        var menu = new Forms.ContextMenuStrip();

        menu.Items.Add("Open ShadowPlay", null, (_, _) => OpenRequested?.Invoke());

        var shareText = _controller.IsSharingRunning ? "Pause sharing" : "Start sharing";
        menu.Items.Add(shareText, null, async (_, _) => await _controller.ToggleSharingAsync());
        menu.Items[^1].Enabled = _controller.Status.State != SharingState.NotConfigured;

        menu.Items.Add(new Forms.ToolStripSeparator());

        var openFolder = menu.Items.Add("Open recordings folder", null, (_, _) => _controller.OpenRecordingsFolderInExplorer());
        openFolder.Enabled = Directory.Exists(_controller.RecordingsFolder);

        menu.Items.Add("Settings", null, (_, _) => SettingsRequested?.Invoke());

        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => ExitRequested?.Invoke());

        _notifyIcon.ContextMenuStrip = menu;
        _notifyIcon.Text = _controller.Status.State switch
        {
            SharingState.Running => $"ShadowPlay - sharing on port {_controller.Status.Port}",
            SharingState.Starting => "ShadowPlay - starting...",
            SharingState.Paused => "ShadowPlay - paused",
            SharingState.Error => "ShadowPlay - problem (click to open)",
            _ => "ShadowPlay",
        };
    }

    /// <summary>Set by App; performs a clean application shutdown.</summary>
    public Action? ExitRequested { get; set; }

    public void Dispose()
    {
        _controller.StateChanged -= RebuildMenu;
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _icon.Dispose();
    }
}
