using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace WidgetTea;

/// <summary>
/// Prüft die Releases des Repositorys (GitHub oder Gitea) auf eine neuere Version und spielt sie ein
/// (Prinzip wie in Lagerfeuer: releases/latest abfragen, Tag als Versionsnummer vergleichen,
/// Entwürfe und Vorabversionen ignorieren).
///
/// Erwartete Release-Assets (erzeugt von build/release.ps1):
///   WidgetTea-&lt;ver&gt;-setup.exe          → wird still mit /S /RESTART ausgeführt
///   WidgetTea-&lt;ver&gt;-setup.exe.sha256   → SHA-256 des Setups; ohne passende Prüfsumme kein Update
/// </summary>
public sealed class UpdateService
{
    private static readonly Assembly AppAssembly = Assembly.GetEntryAssembly() ?? typeof(UpdateService).Assembly;

    public static Version CurrentVersion { get; } = Normalize(AppAssembly.GetName().Version ?? new Version(0, 0, 0));

    /// <summary>z.B. https://github.com/Celestial0579/WidgetTea – aus WidgetTea.csproj (UpdateRepository).</summary>
    public static string? RepositoryUrl { get; } = AppAssembly.GetCustomAttributes<AssemblyMetadataAttribute>()
        .FirstOrDefault(a => a.Key == "UpdateRepository")?.Value is { Length: > 0 } url ? url.TrimEnd('/') : null;

    public static bool IsConfigured => RepositoryUrl != null;

    private static string TempDir => Path.Combine(Path.GetTempPath(), "WidgetTea-Update");

    private readonly HttpClient _http;

    public UpdateService(string? token)
    {
        _http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        _http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("WidgetTea", CurrentVersion.ToString(3)));
        _http.DefaultRequestHeaders.Accept.ParseAdd("application/json");
        if (!string.IsNullOrEmpty(token))
            _http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("token", token);
    }

    /// <summary>
    /// Token der Widget-Einstellungen nur mitschicken, wenn das Update-Repo auf demselben Gitea liegt
    /// (für Repos, die nur angemeldet sichtbar sind) – nie an einen fremden Host.
    /// </summary>
    public static string? TokenFor(AppSettings settings)
    {
        if (RepositoryUrl == null ||
            !Uri.TryCreate(RepositoryUrl, UriKind.Absolute, out var repo) ||
            !Uri.TryCreate(settings.BaseUrl, UriKind.Absolute, out var gitea))
            return null;
        return Uri.Compare(repo, gitea, UriComponents.SchemeAndServer, UriFormat.Unescaped, StringComparison.OrdinalIgnoreCase) == 0
            ? CredentialStore.Load()
            : null;
    }

    /// <summary>Neueres Release oder null. Wirft bei Netzwerkfehlern (Gitea nicht erreichbar).</summary>
    public async Task<UpdateInfo?> CheckAsync(CancellationToken ct = default)
    {
        if (RepositoryUrl == null)
            return null;

        using var resp = await _http.GetAsync(LatestReleaseApi(RepositoryUrl), ct);
        if (resp.StatusCode == HttpStatusCode.NotFound)
            return null; // noch kein Release (oder Repo nicht sichtbar)
        resp.EnsureSuccessStatusCode();

        var release = await resp.Content.ReadFromJsonAsync<GiteaRelease>(ct);
        if (release is null || release.Draft || release.Prerelease)
            return null;
        if (!TryParseVersion(release.TagName, out var version) || version <= CurrentVersion)
            return null;

        var setup = release.Assets.FirstOrDefault(a => a.Name.EndsWith("-setup.exe", StringComparison.OrdinalIgnoreCase));
        var checksum = setup == null ? null
            : release.Assets.FirstOrDefault(a => a.Name.Equals(setup.Name + ".sha256", StringComparison.OrdinalIgnoreCase));

        return new UpdateInfo(version, release.HtmlUrl, setup?.BrowserDownloadUrl, setup?.Name, checksum?.BrowserDownloadUrl);
    }

    /// <summary>Lädt das Setup, prüft die SHA-256-Prüfsumme und gibt den lokalen Pfad zurück.</summary>
    public async Task<string> DownloadAsync(UpdateInfo update, CancellationToken ct = default)
    {
        if (update.SetupUrl == null || update.SetupName == null)
            throw new InvalidOperationException("Das Release enthält kein Setup.");
        if (update.ChecksumUrl == null)
            throw new InvalidOperationException("Das Release enthält keine Prüfsumme – Update wird nicht installiert.");

        var expected = (await _http.GetStringAsync(update.ChecksumUrl, ct)).Trim().Split(' ', '\t', '\r', '\n')[0];

        Directory.CreateDirectory(TempDir);
        var target = Path.Combine(TempDir, Path.GetFileName(update.SetupName));
        using (var resp = await _http.GetAsync(update.SetupUrl, HttpCompletionOption.ResponseHeadersRead, ct))
        {
            resp.EnsureSuccessStatusCode();
            await using var net = await resp.Content.ReadAsStreamAsync(ct);
            await using var file = File.Create(target);
            await net.CopyToAsync(file, ct);
        }

        string actual;
        await using (var file = File.OpenRead(target))
            actual = Convert.ToHexString(await SHA256.HashDataAsync(file, ct));

        if (!actual.Equals(expected, StringComparison.OrdinalIgnoreCase))
        {
            File.Delete(target);
            throw new InvalidOperationException("Die Prüfsumme des Updates stimmt nicht – Download verworfen.");
        }
        return target;
    }

    /// <summary>Startet das Setup still. Es wartet, bis sich die App beendet hat, und startet sie danach neu.</summary>
    public static void LaunchInstaller(string setupPath) =>
        Process.Start(new ProcessStartInfo(setupPath, "/S /RESTART") { UseShellExecute = true });

    /// <summary>Räumt Reste eines vorherigen Updates auf (beim Start aufrufen).</summary>
    public static void CleanupAfterUpdate()
    {
        try
        {
            if (Directory.Exists(TempDir))
                Directory.Delete(TempDir, recursive: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Setup läuft evtl. noch – beim nächsten Start erneut
        }
    }

    /// <summary>
    /// https://github.com/owner/repo         → https://api.github.com/repos/owner/repo/releases/latest
    /// https://host[/unterpfad]/owner/repo   → https://host[/unterpfad]/api/v1/repos/owner/repo/releases/latest (Gitea)
    /// Beide liefern tag_name, html_url, draft, prerelease und assets[].browser_download_url.
    /// </summary>
    internal static string LatestReleaseApi(string repositoryUrl)
    {
        var parts = repositoryUrl.TrimEnd('/').Split('/');
        var (owner, repo) = (parts[^2], parts[^1]);
        return new Uri(repositoryUrl).Host.Equals("github.com", StringComparison.OrdinalIgnoreCase)
            ? $"https://api.github.com/repos/{owner}/{repo}/releases/latest"
            : $"{string.Join('/', parts[..^2])}/api/v1/repos/{owner}/{repo}/releases/latest";
    }

    internal static bool TryParseVersion(string? tag, out Version version)
    {
        version = new Version(0, 0, 0);
        if (string.IsNullOrWhiteSpace(tag))
            return false;
        var s = tag.Trim().TrimStart('v', 'V');
        if (s.IndexOfAny(['-', '+']) >= 0)
            return false; // Vorabversion (z.B. 1.2.0-beta) nie automatisch anbieten
        if (!Version.TryParse(s.Contains('.') ? s : s + ".0", out var v))
            return false;
        version = Normalize(v);
        return true;
    }

    private static Version Normalize(Version v) => new(v.Major, Math.Max(0, v.Minor), Math.Max(0, v.Build));

    private sealed class GiteaRelease
    {
        [JsonPropertyName("tag_name")] public string TagName { get; set; } = "";
        [JsonPropertyName("html_url")] public string HtmlUrl { get; set; } = "";
        [JsonPropertyName("draft")] public bool Draft { get; set; }
        [JsonPropertyName("prerelease")] public bool Prerelease { get; set; }
        [JsonPropertyName("assets")] public GiteaAsset[] Assets { get; set; } = [];
    }

    private sealed class GiteaAsset
    {
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("browser_download_url")] public string BrowserDownloadUrl { get; set; } = "";
    }
}

public sealed record UpdateInfo(Version Version, string ReleaseUrl, string? SetupUrl, string? SetupName, string? ChecksumUrl);
