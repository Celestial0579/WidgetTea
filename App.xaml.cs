using System.Threading;
using System.Windows;

namespace WidgetTea;

public partial class App : Application
{
    private Mutex? _singleInstance;
    private TrayIcon? _tray;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _singleInstance = new Mutex(true, @"Local\WidgetTea.SingleInstance", out bool isFirst);
        if (!isFirst)
        {
            Shutdown();
            return;
        }

        var settings = AppSettings.Load();

        // Autostart legt das Setup an (abwählbar); hier nur den Pfad aktuell halten, falls die EXE verschoben wurde.
        if (Autostart.Enabled)
            Autostart.Enabled = true;

        var window = new MainWindow(settings);
        var updates = new UpdateController(settings);
        _tray = new TrayIcon(window, updates);
        window.Show();
        updates.Start();

        if (!settings.IsComplete || !CredentialStore.HasToken)
            window.OpenSettings();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        _singleInstance?.Dispose();
        base.OnExit(e);
    }
}
