using System;
using System.Drawing;
using System.Windows.Forms;

namespace WidgetTea;

public sealed class TrayIcon : IDisposable
{
    private readonly NotifyIcon _icon;
    private readonly Icon _image;

    public TrayIcon(MainWindow window, UpdateController updates)
    {
        using (var stream = typeof(TrayIcon).Assembly.GetManifestResourceStream("WidgetTea.ico")!)
            _image = new Icon(stream, SystemInformation.SmallIconSize);

        var install = new ToolStripMenuItem { Visible = false, Font = new Font(SystemFonts.MenuFont!, FontStyle.Bold) };
        install.Click += (_, _) => _ = updates.InstallAsync();
        var refresh = new ToolStripMenuItem("Jetzt aktualisieren", null, (_, _) => _ = window.RefreshAsync());
        var show = new ToolStripMenuItem("Widget anzeigen", null, (_, _) => window.Show());
        var locked = new ToolStripMenuItem("Position fixieren") { CheckOnClick = true };
        locked.Click += (_, _) => window.Locked = locked.Checked;
        var autostart = new ToolStripMenuItem("Mit Windows starten") { CheckOnClick = true };
        autostart.Click += (_, _) => Autostart.Enabled = autostart.Checked;
        var settings = new ToolStripMenuItem("Einstellungen…", null, (_, _) => window.OpenSettings());
        var checkUpdates = new ToolStripMenuItem("Nach Updates suchen", null, (_, _) => _ = updates.CheckAsync(manual: true))
        {
            Enabled = UpdateService.IsConfigured,
        };
        var version = new ToolStripMenuItem($"Version {UpdateService.CurrentVersion.ToString(3)}") { Enabled = false };
        var exit = new ToolStripMenuItem("Beenden", null, (_, _) => System.Windows.Application.Current.Shutdown());

        var menu = new ContextMenuStrip();
        menu.Items.AddRange([install, refresh, show, new ToolStripSeparator(), locked, autostart,
            new ToolStripSeparator(), settings, checkUpdates, version, new ToolStripSeparator(), exit]);
        settings.Font = new Font(settings.Font, FontStyle.Bold);
        menu.Opening += (_, _) =>
        {
            locked.Checked = window.Locked;
            autostart.Checked = Autostart.Enabled;
            install.Visible = updates.Available != null;
            if (updates.Available != null)
                install.Text = $"Update auf {updates.Available.Version.ToString(3)} installieren";
        };

        _icon = new NotifyIcon { Icon = _image, Text = "WidgetTea – Gitea Contributions", ContextMenuStrip = menu, Visible = true };
        _icon.DoubleClick += (_, _) => window.OpenSettings();
        _icon.BalloonTipClicked += (_, _) =>
        {
            if (updates.Available != null)
                _ = updates.InstallAsync();
        };
        window.StatusChanged += text => _icon.Text = Truncate("WidgetTea – " + text, 127);
        updates.Message += text => _icon.ShowBalloonTip(5000, "WidgetTea", text, ToolTipIcon.Info);
        updates.UpdateAvailable += info => _icon.ShowBalloonTip(10000, "WidgetTea",
            $"Version {info.Version.ToString(3)} ist verfügbar – hier klicken zum Installieren.", ToolTipIcon.Info);
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max];

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _image.Dispose();
    }
}
