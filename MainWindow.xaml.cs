using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;

namespace WidgetTea;

public partial class MainWindow : Window
{
    private const double Cell = 13;
    private const double Gap = 2;
    private const double LeftPad = 30;
    private const double TopPad = 18;
    private const int Weeks = 53;

    private static readonly CultureInfo German = CultureInfo.GetCultureInfo("de-DE");
    private static readonly Brush LabelBrush = Freeze(new SolidColorBrush(Color.FromRgb(0xD4, 0xD4, 0xD4)));
    private static readonly Brush OnlineBrush = Freeze(new SolidColorBrush(Color.FromRgb(0x3F, 0xB9, 0x50)));
    private static readonly Brush OfflineBrush = Freeze(new SolidColorBrush(Color.FromRgb(0x6E, 0x76, 0x81)));
    private static readonly Brush ErrorBrush = Freeze(new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22)));

    // Stufe 0 = keine Contributions, 1–4 = zunehmend hellere Blautöne wie in der Gitea-Heatmap.
    private static readonly Brush[] Levels =
    [
        Freeze(new SolidColorBrush(Color.FromRgb(0x2D, 0x2E, 0x31))),
        Freeze(new SolidColorBrush(Color.FromRgb(0x26, 0x40, 0x6A))),
        Freeze(new SolidColorBrush(Color.FromRgb(0x30, 0x56, 0x90))),
        Freeze(new SolidColorBrush(Color.FromRgb(0x45, 0x73, 0xBC))),
        Freeze(new SolidColorBrush(Color.FromRgb(0x7D, 0xA2, 0xDC))),
    ];

    private AppSettings _config;
    private HeatmapCache? _cache;
    private readonly DispatcherTimer _refreshTimer = new();
    private readonly DispatcherTimer _dayTimer = new() { Interval = TimeSpan.FromMinutes(1) };
    private readonly SemaphoreSlim _refreshLock = new(1, 1);
    private DateOnly _renderedDay;

    public event Action<string>? StatusChanged;

    public MainWindow(AppSettings config)
    {
        InitializeComponent();
        _config = config;
        _cache = HeatmapCache.Load();

        BuildLegend();
        ApplyConfig();
        RenderFromCache();
        RestorePosition();

        _refreshTimer.Tick += (_, _) => _ = RefreshAsync();
        _refreshTimer.Start();

        // Datumswechsel um Mitternacht: Raster neu zeichnen, auch wenn offline.
        _dayTimer.Tick += (_, _) =>
        {
            if (DateOnly.FromDateTime(DateTime.Today) != _renderedDay)
                Render();
        };
        _dayTimer.Start();

        NetworkChange.NetworkAvailabilityChanged += (_, e) =>
        {
            if (e.IsAvailable)
                Dispatcher.InvokeAsync(() => RefreshSoon());
        };
        NetworkChange.NetworkAddressChanged += (_, _) => Dispatcher.InvokeAsync(() => RefreshSoon());
        SystemEvents.PowerModeChanged += (_, e) =>
        {
            if (e.Mode == PowerModes.Resume)
                Dispatcher.InvokeAsync(() => RefreshSoon());
        };

        Loaded += (_, _) => _ = RefreshAsync();
        StateChanged += (_, _) =>
        {
            if (WindowState != WindowState.Normal)
                WindowState = WindowState.Normal;
        };
    }

    public bool Locked
    {
        get => _config.Locked;
        set
        {
            _config.Locked = value;
            _config.Save();
        }
    }

    private SettingsWindow? _settingsWindow;

    public void OpenSettings()
    {
        if (_settingsWindow != null)
        {
            _settingsWindow.Activate();
            return;
        }

        _settingsWindow = new SettingsWindow(_config);
        bool saved = _settingsWindow.ShowDialog() == true;
        _settingsWindow = null;
        if (!saved)
            return;

        ApplyConfig();
        RenderFromCache();
        _ = RefreshAsync();
    }

    private void ApplyConfig()
    {
        _refreshTimer.Interval = TimeSpan.FromMinutes(Math.Max(1, _config.RefreshMinutes));
        TitleText.Text = string.IsNullOrWhiteSpace(_config.Username) ? "Gitea" : $"Gitea · {_config.Username}";
    }

    private DispatcherTimer? _soonTimer;

    /// <summary>Netzwerkereignisse kommen oft gehäuft – kurz warten, bis das Netz wirklich steht.</summary>
    private void RefreshSoon()
    {
        _soonTimer?.Stop();
        _soonTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        _soonTimer.Tick += (_, _) =>
        {
            _soonTimer?.Stop();
            _ = RefreshAsync();
        };
        _soonTimer.Start();
    }

    public async Task RefreshAsync()
    {
        if (!_config.IsComplete)
        {
            SetStatus("Bitte Einstellungen ausfüllen (Doppelklick aufs Tray-Icon)", ErrorBrush);
            return;
        }
        if (!await _refreshLock.WaitAsync(0))
            return;

        try
        {
            var days = await GiteaClient.FetchHeatmapAsync(_config, CredentialStore.Load(), CancellationToken.None);
            _cache = new HeatmapCache
            {
                Username = _config.Username,
                BaseUrl = _config.BaseUrl,
                LastSync = DateTimeOffset.Now,
                Days = days,
            };
            _cache.Save();
            Render();
            SetStatus($"Aktualisiert {_cache.LastSync:HH:mm}", OnlineBrush);
        }
        catch (GiteaAuthException ex)
        {
            RenderFromCache();
            SetStatus(ex.Message + CacheSuffix(), ErrorBrush);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            RenderFromCache();
            SetStatus(HasCache ? $"Offline – Stand {_cache!.LastSync.ToString("dd.MM. HH:mm", German)}" : "Gitea nicht erreichbar – noch keine Daten",
                OfflineBrush);
        }
        finally
        {
            _refreshLock.Release();
        }
    }

    private bool HasCache => _cache != null && _cache.Matches(_config);

    private string CacheSuffix() => HasCache ? $" – Stand {_cache!.LastSync.ToString("dd.MM. HH:mm", German)}" : "";

    private void RenderFromCache()
    {
        Render();
        if (HasCache)
            SetStatus($"Stand {_cache!.LastSync.ToString("dd.MM. HH:mm", German)}", OfflineBrush);
    }

    private void SetStatus(string text, Brush dot)
    {
        StatusText.Text = text;
        StatusDot.Fill = dot;
        StatusChanged?.Invoke(text);
    }

    private void Render()
    {
        var days = HasCache ? _cache!.Days : new Dictionary<DateOnly, int>();
        var today = DateOnly.FromDateTime(DateTime.Today);
        _renderedDay = today;

        // Wie Gitea: Spalten = Wochen (Sonntag oben), letzte Spalte = aktuelle Woche.
        var start = today.AddDays(-(int)today.DayOfWeek - (Weeks - 1) * 7);

        int max = Math.Max(1, days.Where(kv => kv.Key >= start && kv.Key <= today).Select(kv => kv.Value).DefaultIfEmpty(0).Max());
        int total = days.Where(kv => kv.Key >= today.AddYears(-1) && kv.Key <= today).Sum(kv => kv.Value);

        HeatCanvas.Children.Clear();
        HeatCanvas.Width = LeftPad + Weeks * (Cell + Gap) - Gap;
        HeatCanvas.Height = TopPad + 7 * (Cell + Gap) - Gap;

        foreach (var (row, label) in new[] { (1, "Mo"), (3, "Mi"), (5, "Fr") })
            AddLabel(label, 0, TopPad + row * (Cell + Gap) + Cell / 2 - 8);

        for (int w = 0; w < Weeks; w++)
        {
            double x = LeftPad + w * (Cell + Gap);
            for (int d = 0; d < 7; d++)
            {
                var date = start.AddDays(w * 7 + d);
                if (date > today)
                    break;

                // Monatsname über der Woche, die den Monatsersten enthält.
                if (date.Day == 1 && w < Weeks - 1)
                    AddLabel(German.DateTimeFormat.GetAbbreviatedMonthName(date.Month).TrimEnd('.'), x, 0);

                int count = days.GetValueOrDefault(date);
                var rect = new Rectangle
                {
                    Width = Cell,
                    Height = Cell,
                    RadiusX = 2,
                    RadiusY = 2,
                    Fill = Levels[LevelFor(count, max)],
                    ToolTip = $"{count} {(count == 1 ? "Beitrag" : "Beiträge")} am {date.ToString("ddd, dd.MM.yyyy", German)}",
                };
                ToolTipService.SetInitialShowDelay(rect, 150);
                Canvas.SetLeft(rect, x);
                Canvas.SetTop(rect, TopPad + d * (Cell + Gap));
                HeatCanvas.Children.Add(rect);
            }
        }

        SummaryText.Text = $"{total.ToString("N0", German)} Beiträge im letzten Jahr · Serie {Streak(days, today)} T.";
    }

    private static int LevelFor(int count, int max) =>
        count <= 0 ? 0 : Math.Clamp((int)Math.Ceiling(count * 4.0 / max), 1, 4);

    private static int Streak(Dictionary<DateOnly, int> days, DateOnly today)
    {
        var day = days.GetValueOrDefault(today) > 0 ? today : today.AddDays(-1);
        int streak = 0;
        while (days.GetValueOrDefault(day) > 0)
        {
            streak++;
            day = day.AddDays(-1);
        }
        return streak;
    }

    private void AddLabel(string text, double x, double y)
    {
        var label = new TextBlock { Text = text, Foreground = LabelBrush, FontSize = 11 };
        Canvas.SetLeft(label, x);
        Canvas.SetTop(label, y);
        HeatCanvas.Children.Add(label);
    }

    private void BuildLegend()
    {
        Legend.Children.Add(new TextBlock { Text = "Weniger", Foreground = OfflineBrush, FontSize = 10, Margin = new Thickness(0, 0, 4, 0) });
        foreach (var brush in Levels)
            Legend.Children.Add(new Rectangle { Width = 10, Height = 10, RadiusX = 2, RadiusY = 2, Fill = brush, Margin = new Thickness(1, 0, 1, 0) });
        Legend.Children.Add(new TextBlock { Text = "Mehr", Foreground = OfflineBrush, FontSize = 10, Margin = new Thickness(4, 0, 0, 0) });
    }

    // ---- Fensterverhalten: auf Desktop-Ebene, nicht in Taskleiste/Alt-Tab, verschiebbar ----

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var hwnd = new WindowInteropHelper(this).Handle;

        long exStyle = NativeMethods.GetWindowLongPtr(hwnd, NativeMethods.GWL_EXSTYLE).ToInt64();
        exStyle = (exStyle | NativeMethods.WS_EX_TOOLWINDOW) & ~NativeMethods.WS_EX_APPWINDOW;
        NativeMethods.SetWindowLongPtr(hwnd, NativeMethods.GWL_EXSTYLE, new IntPtr(exStyle));

        // Owner = Progman: Widget bleibt bei Win+D ("Desktop anzeigen") sichtbar.
        var progman = NativeMethods.FindWindow("Progman", null);
        if (progman != IntPtr.Zero)
            NativeMethods.SetWindowLongPtr(hwnd, NativeMethods.GWLP_HWNDPARENT, progman);

        HwndSource.FromHwnd(hwnd)?.AddHook(WndProc);
        SendToBottom(hwnd);
    }

    private static IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == NativeMethods.WM_WINDOWPOSCHANGING)
        {
            var pos = Marshal.PtrToStructure<NativeMethods.WINDOWPOS>(lParam);
            if ((pos.flags & NativeMethods.SWP_NOZORDER) == 0)
            {
                pos.hwndInsertAfter = NativeMethods.HWND_BOTTOM;
                Marshal.StructureToPtr(pos, lParam, false);
            }
        }
        return IntPtr.Zero;
    }

    private static void SendToBottom(IntPtr hwnd) =>
        NativeMethods.SetWindowPos(hwnd, NativeMethods.HWND_BOTTOM, 0, 0, 0, 0,
            NativeMethods.SWP_NOMOVE | NativeMethods.SWP_NOSIZE | NativeMethods.SWP_NOACTIVATE);

    private void OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (_config.Locked)
            return;
        DragMove();
        _config.Left = Left;
        _config.Top = Top;
        _config.Save();
        SendToBottom(new WindowInteropHelper(this).Handle);
    }

    private void RestorePosition()
    {
        WindowStartupLocation = WindowStartupLocation.Manual;
        var area = SystemParameters.WorkArea;
        double left = _config.Left ?? area.Right - 860;
        double top = _config.Top ?? area.Top + 40;

        // Falls ein Monitor abgesteckt wurde: zurück in den sichtbaren Bereich.
        if (left < SystemParameters.VirtualScreenLeft || left > SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 100)
            left = area.Right - 860;
        if (top < SystemParameters.VirtualScreenTop || top > SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 50)
            top = area.Top + 40;

        Left = Math.Max(area.Left, left);
        Top = top;
    }

    private static Brush Freeze(SolidColorBrush brush)
    {
        brush.Freeze();
        return brush;
    }
}
