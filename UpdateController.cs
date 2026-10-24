using System;
using System.IO;
using System.Net.Http;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace WidgetTea;

/// <summary>
/// Sucht kurz nach dem Start und danach alle 6 Stunden nach Updates – nur wenn das Gitea erreichbar ist,
/// sonst still beim nächsten Mal. Installiert automatisch, wenn in den Einstellungen aktiviert.
/// </summary>
public sealed class UpdateController
{
    private static readonly TimeSpan FirstCheck = TimeSpan.FromMinutes(1);
    private static readonly TimeSpan Interval = TimeSpan.FromHours(6);

    private readonly AppSettings _settings;
    private readonly DispatcherTimer _timer = new();
    private bool _busy;

    public UpdateInfo? Available { get; private set; }

    /// <summary>Neues Update gefunden, das nicht automatisch installiert wird.</summary>
    public event Action<UpdateInfo>? UpdateAvailable;

    /// <summary>Hinweis für den Nutzer (Tray-Sprechblase).</summary>
    public event Action<string>? Message;

    public UpdateController(AppSettings settings)
    {
        _settings = settings;
        _timer.Tick += (_, _) =>
        {
            _timer.Interval = Interval;
            _ = CheckAsync(manual: false);
        };
    }

    public void Start()
    {
        UpdateService.CleanupAfterUpdate();
        if (!UpdateService.IsConfigured)
            return;
        _timer.Interval = FirstCheck;
        _timer.Start();
    }

    public async Task CheckAsync(bool manual)
    {
        if (!UpdateService.IsConfigured)
        {
            if (manual)
                Message?.Invoke("In diesem Build ist keine Update-Quelle hinterlegt.");
            return;
        }
        if (_busy)
            return;

        _busy = true;
        try
        {
            var info = await new UpdateService(UpdateService.TokenFor(_settings)).CheckAsync();
            if (info == null)
            {
                if (manual)
                    Message?.Invoke($"WidgetTea {UpdateService.CurrentVersion.ToString(3)} ist aktuell.");
                return;
            }

            bool isNew = Available?.Version != info.Version;
            Available = info;
            if (_settings.AutoUpdate || manual)
                await InstallCoreAsync();
            else if (isNew)
                UpdateAvailable?.Invoke(info);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            if (manual)
                Message?.Invoke("Update-Server nicht erreichbar – später erneut versuchen.");
        }
        finally
        {
            _busy = false;
        }
    }

    public async Task InstallAsync()
    {
        if (_busy || Available == null)
            return;
        _busy = true;
        try
        {
            await InstallCoreAsync();
        }
        finally
        {
            _busy = false;
        }
    }

    private async Task InstallCoreAsync()
    {
        try
        {
            var update = Available!;
            Message?.Invoke($"Update auf {update.Version.ToString(3)} wird installiert …");
            var setup = await new UpdateService(UpdateService.TokenFor(_settings)).DownloadAsync(update);
            UpdateService.LaunchInstaller(setup);
            Application.Current.Shutdown();
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or InvalidOperationException or IOException)
        {
            Message?.Invoke("Update fehlgeschlagen: " + ex.Message);
        }
    }
}
