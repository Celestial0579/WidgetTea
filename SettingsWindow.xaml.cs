using System;
using System.Diagnostics;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;

namespace WidgetTea;

public partial class SettingsWindow : Window
{
    private static readonly Brush OkBrush = new SolidColorBrush(Color.FromRgb(0x3F, 0xB9, 0x50));
    private static readonly Brush FailBrush = new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22));

    private readonly AppSettings _settings;

    public SettingsWindow(AppSettings settings)
    {
        InitializeComponent();
        _settings = settings;

        BaseUrlBox.Text = settings.BaseUrl;
        UsernameBox.Text = settings.Username;
        RefreshBox.Text = settings.RefreshMinutes.ToString();
        AutostartBox.IsChecked = Autostart.Enabled;
        IgnoreCertBox.IsChecked = settings.IgnoreCertificateErrors;
        AutoUpdateBox.IsChecked = settings.AutoUpdate;
        AutoUpdateBox.IsEnabled = UpdateService.IsConfigured;
        VersionText.Text = $"WidgetTea {UpdateService.CurrentVersion.ToString(3)} · MIT-Lizenz · © 2026 Tim Heyne";
        TokenHint.Text = CredentialStore.HasToken
            ? "Ein Token ist verschlüsselt gespeichert. Leer lassen, um es zu behalten."
            : "Wird verschlüsselt im Windows-Profil gespeichert (DPAPI).";

        Loaded += (_, _) => (string.IsNullOrWhiteSpace(BaseUrlBox.Text) ? BaseUrlBox : UsernameBox).Focus();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        int dark = 1;
        NativeMethods.DwmSetWindowAttribute(new WindowInteropHelper(this).Handle,
            NativeMethods.DWMWA_USE_IMMERSIVE_DARK_MODE, ref dark, sizeof(int));
    }

    /// <summary>Werte aus dem Formular; null + Meldung bei ungültiger Eingabe.</summary>
    private AppSettings? ReadForm()
    {
        var url = BaseUrlBox.Text.Trim().TrimEnd('/');
        if (url.EndsWith("/api/v1", StringComparison.OrdinalIgnoreCase))
            url = url[..^"/api/v1".Length];
        if (!url.Contains("://"))
            url = "https://" + url;

        var candidate = new AppSettings
        {
            BaseUrl = url,
            Username = UsernameBox.Text.Trim(),
            RefreshMinutes = int.TryParse(RefreshBox.Text.Trim(), out int minutes) ? Math.Clamp(minutes, 1, 1440) : -1,
            TimeoutSeconds = _settings.TimeoutSeconds,
            IgnoreCertificateErrors = IgnoreCertBox.IsChecked == true,
        };

        if (!candidate.IsComplete)
        {
            ShowResult("Bitte Gitea-Adresse und Benutzername angeben.", FailBrush);
            return null;
        }
        if (candidate.RefreshMinutes < 0)
        {
            ShowResult("Intervall muss eine Zahl (Minuten) sein.", FailBrush);
            return null;
        }
        return candidate;
    }

    private string? EnteredOrStoredToken() =>
        TokenBox.Password.Length > 0 ? TokenBox.Password.Trim() : CredentialStore.Load();

    private async void OnTestClick(object sender, RoutedEventArgs e)
    {
        var candidate = ReadForm();
        if (candidate == null)
            return;

        TestButton.IsEnabled = false;
        ShowResult("Verbinde …", Brushes.Gray);
        try
        {
            var days = await GiteaClient.FetchHeatmapAsync(candidate, EnteredOrStoredToken(), CancellationToken.None);
            int total = 0;
            foreach (var count in days.Values)
                total += count;
            ShowResult($"Verbindung OK – {total} Beiträge im letzten Jahr.", OkBrush);
        }
        catch (GiteaAuthException ex)
        {
            ShowResult(ex.Message, FailBrush);
        }
        catch (HttpRequestException ex)
        {
            ShowResult("Nicht erreichbar: " + (ex.InnerException?.Message ?? ex.Message), FailBrush);
        }
        catch (TaskCanceledException)
        {
            ShowResult($"Keine Antwort innerhalb von {candidate.TimeoutSeconds} s.", FailBrush);
        }
        finally
        {
            TestButton.IsEnabled = true;
        }
    }

    private void OnSaveClick(object sender, RoutedEventArgs e)
    {
        var candidate = ReadForm();
        if (candidate == null)
            return;

        _settings.BaseUrl = candidate.BaseUrl;
        _settings.Username = candidate.Username;
        _settings.RefreshMinutes = candidate.RefreshMinutes;
        _settings.IgnoreCertificateErrors = candidate.IgnoreCertificateErrors;
        _settings.AutoUpdate = AutoUpdateBox.IsChecked == true;
        _settings.Save();

        if (TokenBox.Password.Length > 0)
            CredentialStore.Save(TokenBox.Password.Trim());
        Autostart.Enabled = AutostartBox.IsChecked == true;

        DialogResult = true;
    }

    private void OnTokenLinkClick(object sender, RoutedEventArgs e)
    {
        var url = BaseUrlBox.Text.Trim().TrimEnd('/');
        if (string.IsNullOrEmpty(url))
        {
            ShowResult("Zuerst die Gitea-Adresse eintragen.", FailBrush);
            return;
        }
        if (!url.Contains("://"))
            url = "https://" + url;
        Process.Start(new ProcessStartInfo(url + "/user/settings/applications") { UseShellExecute = true });
    }

    private void ShowResult(string text, Brush color)
    {
        ResultText.Text = text;
        ResultText.Foreground = color;
        ResultBorder.Visibility = Visibility.Visible;
    }
}
