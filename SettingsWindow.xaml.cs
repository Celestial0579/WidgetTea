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
        AppSettings.TryNormalizeBaseUrl(BaseUrlBox.Text, out var url);

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
        catch (GiteaException ex)
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
        if (string.IsNullOrWhiteSpace(BaseUrlBox.Text))
        {
            ShowResult("Zuerst die Gitea-Adresse eintragen.", FailBrush);
            return;
        }
        // Die Adresse geht an die Shell. Nur http und https: Alles andere öffnete irgendein Programm oder gar keines.
        if (!AppSettings.TryNormalizeBaseUrl(BaseUrlBox.Text, out var url))
        {
            ShowResult("Die Gitea-Adresse muss mit http:// oder https:// beginnen.", FailBrush);
            return;
        }
        try
        {
            Process.Start(new ProcessStartInfo(url + "/user/settings/applications") { UseShellExecute = true });
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            ShowResult("Der Browser ließ sich nicht öffnen.", FailBrush);
        }
    }

    private void OnBaseUrlChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        // Das Ereignis kann kommen, bevor der Hinweis unter dem Feld angelegt ist.
        if (HttpWarning is not null)
            HttpWarning.Visibility = AppSettings.IsUnencrypted(BaseUrlBox.Text) ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowResult(string text, Brush color)
    {
        ResultText.Text = text;
        ResultText.Foreground = color;
        ResultBorder.Visibility = Visibility.Visible;
    }
}
