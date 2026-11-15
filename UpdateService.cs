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

    /// <summary>Ordner, unter dem die geladenen Setups liegen; in Tests ein anderer als im Betrieb.</summary>
    internal string DownloadRoot { get; init; } = TempDir;

    /// <summary>Obergrenze für das Setup. Heute rund 0,2 MB; mehr als das Vielfache davon ist kein Setup von uns.</summary>
    internal const long MaxSetupBytes = 50L * 1024 * 1024;

    /// <summary>Obergrenze für die Prüfsummen-Datei (eine Zeile: 64 Hex-Zeichen und der Dateiname).</summary>
    internal const long MaxChecksumBytes = 1024;

    private readonly HttpClient _http;
    private readonly string? _token;
    private readonly string? _tokenRepository;

    public UpdateService(string? token) : this(token, new HttpClientHandler(), RepositoryUrl)
    {
    }

    /// <summary>Dasselbe über einen vorgegebenen Transport, damit sich Abfrage und Download prüfen lassen.</summary>
    /// <param name="tokenRepository">Update-Repo, an dessen Host allein das Token geht (Vorgabe: das des Builds).</param>
    internal UpdateService(string? token, HttpMessageHandler handler, string? tokenRepository = null)
    {
        _http = new HttpClient(handler) { Timeout = TimeSpan.FromMinutes(5) };
        _http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("WidgetTea", CurrentVersion.ToString(3)));
        _http.DefaultRequestHeaders.Accept.ParseAdd("application/json");
        // Das Token geht nicht als Standard-Header mit, sondern nur in Anfragen an den Host des Update-Repos
        // (siehe Send): Eine Download-Adresse auf einem anderen Host bekommt es nie.
        _token = string.IsNullOrEmpty(token) ? null : token;
        _tokenRepository = tokenRepository;
    }

    private Task<HttpResponseMessage> Send(string url, HttpCompletionOption completion, CancellationToken ct)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, url);
        if (_token != null && _tokenRepository != null && IsRepositoryHost(request.RequestUri!, _tokenRepository))
            request.Headers.Authorization = new AuthenticationHeaderValue("token", _token);
        return _http.SendAsync(request, completion, ct);
    }

    /// <summary>Gehört die Adresse zum Host des Update-Repos (bei GitHub auch zu dessen API-Host)?</summary>
    internal static bool IsRepositoryHost(Uri uri, string repositoryUrl)
    {
        if (!Uri.TryCreate(repositoryUrl, UriKind.Absolute, out var repo))
            return false;
        var api = new Uri(LatestReleaseApi(repositoryUrl));
        return uri.Host.Equals(repo.Host, StringComparison.OrdinalIgnoreCase) && uri.Port == repo.Port
            || uri.Host.Equals(api.Host, StringComparison.OrdinalIgnoreCase) && uri.Port == api.Port;
    }

    /// <summary>
    /// Nur Dateien aus den Releases des Update-Repos selbst, mit dessen Schema:
    /// https://github.com/owner/repo/releases/download/… bzw. https://gitea/[unterpfad/]owner/repo/releases/download/…
    /// Ein Repo über https (wie das ausgelieferte auf GitHub) lässt also nur https zu. Ein Gitea, das selbst nur über
    /// http erreichbar ist, liefert schon die Release-Liste ungeschützt; https allein für die Downloads schützte dort
    /// nichts. Den Weiterleitungen von dort (bei GitHub auf den Speicher-Host) folgt der Client danach selbst.
    /// </summary>
    internal static bool IsReleaseDownload(string? url, string repositoryUrl)
    {
        if (url == null ||
            !Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            !Uri.TryCreate(repositoryUrl.TrimEnd('/'), UriKind.Absolute, out var repo) ||
            repo.Scheme is not ("https" or "http") || uri.Scheme != repo.Scheme ||
            !uri.Host.Equals(repo.Host, StringComparison.OrdinalIgnoreCase) || uri.Port != repo.Port ||
            !string.IsNullOrEmpty(uri.UserInfo))
            return false;
        var prefix = repo.AbsolutePath.TrimEnd('/') + "/releases/download/";
        // AbsolutePath ist normalisiert: „..“ ist schon aufgelöst und führt nicht aus dem Präfix hinaus.
        return uri.AbsolutePath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) && uri.AbsolutePath.Length > prefix.Length;
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
    public Task<UpdateInfo?> CheckAsync(CancellationToken ct = default) =>
        RepositoryUrl == null ? Task.FromResult<UpdateInfo?>(null) : CheckAsync(RepositoryUrl, CurrentVersion, ct);

    /// <summary>Die Abfrage selbst, mit Repository und laufender Version als Angaben von außen.</summary>
    internal async Task<UpdateInfo?> CheckAsync(string repositoryUrl, Version currentVersion, CancellationToken ct = default)
    {
        using var resp = await Send(LatestReleaseApi(repositoryUrl), HttpCompletionOption.ResponseContentRead, ct);
        if (resp.StatusCode == HttpStatusCode.NotFound)
            return null; // noch kein Release (oder Repo nicht sichtbar)
        resp.EnsureSuccessStatusCode();

        var release = await resp.Content.ReadFromJsonAsync<GiteaRelease>(ct);
        if (release is null || release.Draft || release.Prerelease)
            return null;
        if (!TryParseVersion(release.TagName, out var version) || version <= currentVersion)
            return null;

        // Unvollständige Antworten (assets oder name fehlen) gelten als „kein Setup“, nicht als Fehler. Dateien, die
        // nicht aus den Releases des Update-Repos über https kommen, werden nicht angefasst.
        var assets = (release.Assets ?? []).OfType<GiteaAsset>()
            .Where(a => a.Name is { Length: > 0 } && IsReleaseDownload(a.BrowserDownloadUrl, repositoryUrl))
            .ToArray();
        var setup = assets.FirstOrDefault(a => a.Name!.EndsWith("-setup.exe", StringComparison.OrdinalIgnoreCase));
        var checksum = setup == null ? null
            : assets.FirstOrDefault(a => a.Name!.Equals(setup.Name + ".sha256", StringComparison.OrdinalIgnoreCase));

        return new UpdateInfo(version, release.HtmlUrl ?? repositoryUrl, setup?.BrowserDownloadUrl, setup?.Name, checksum?.BrowserDownloadUrl);
    }

    /// <summary>Lädt das Setup, prüft die SHA-256-Prüfsumme und gibt den lokalen Pfad zurück.</summary>
    public async Task<string> DownloadAsync(UpdateInfo update, CancellationToken ct = default)
    {
        if (update.SetupUrl == null || update.SetupName == null)
            throw new InvalidOperationException("Das Release enthält kein Setup.");
        if (update.ChecksumUrl == null)
            throw new InvalidOperationException("Das Release enthält keine Prüfsumme – Update wird nicht installiert.");

        string checksumText;
        using (var resp = await Send(update.ChecksumUrl, HttpCompletionOption.ResponseHeadersRead, ct))
        {
            resp.EnsureSuccessStatusCode();
            using var buffer = new MemoryStream();
            await CopyLimitedAsync(resp, buffer, MaxChecksumBytes, "Die Prüfsummen-Datei", ct);
            checksumText = System.Text.Encoding.UTF8.GetString(buffer.ToArray());
        }
        var expected = checksumText.Trim().Split(' ', '\t', '\r', '\n')[0];

        // Jeder Download bekommt seinen eigenen Ordner. Läuft das Setup eines früheren Versuchs noch (es zeigt etwa
        // noch seinen Hinweis), hält es seine Datei fest; ein zweiter Download unter demselben Namen scheiterte daran.
        var folder = Path.Combine(DownloadRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var target = Path.Combine(folder, Path.GetFileName(update.SetupName));
        try
        {
            using var resp = await Send(update.SetupUrl, HttpCompletionOption.ResponseHeadersRead, ct);
            resp.EnsureSuccessStatusCode();
            await using var file = File.Create(target);
            await CopyLimitedAsync(resp, file, MaxSetupBytes, "Das Setup", ct);
        }
        catch
        {
            TryDelete(folder);
            throw;
        }

        string actual;
        await using (var file = File.OpenRead(target))
            actual = Convert.ToHexString(await SHA256.HashDataAsync(file, ct));

        if (!actual.Equals(expected, StringComparison.OrdinalIgnoreCase))
        {
            Directory.Delete(folder, recursive: true);
            throw new InvalidOperationException("Die Prüfsumme des Updates stimmt nicht – Download verworfen.");
        }
        return target;
    }

    /// <summary>Kopiert den Inhalt der Antwort, höchstens <paramref name="limit"/> Bytes; mehr ist ein Fehler.</summary>
    private static async Task CopyLimitedAsync(HttpResponseMessage resp, Stream target, long limit, string what, CancellationToken ct)
    {
        if (resp.Content.Headers.ContentLength is long announced && announced > limit)
            throw new InvalidOperationException($"{what} ist größer als erlaubt ({announced} Bytes) – Update verworfen.");
        await using var net = await resp.Content.ReadAsStreamAsync(ct);
        var buffer = new byte[81920];
        long total = 0;
        int read;
        while ((read = await net.ReadAsync(buffer, ct)) > 0)
        {
            total += read;
            if (total > limit)
                throw new InvalidOperationException($"{what} ist größer als erlaubt – Update verworfen.");
            await target.WriteAsync(buffer.AsMemory(0, read), ct);
        }
    }

    private static void TryDelete(string folder)
    {
        try
        {
            Directory.Delete(folder, recursive: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    /// <summary>Startet das Setup still. Es wartet, bis sich die App beendet hat, und startet sie danach neu.</summary>
    public static void LaunchInstaller(string setupPath) =>
        Process.Start(new ProcessStartInfo(setupPath, "/S /RESTART") { UseShellExecute = true });

    /// <summary>Räumt Reste vorheriger Updates auf (beim Start aufrufen).</summary>
    public static void CleanupAfterUpdate() => Cleanup(TempDir);

    /// <summary>
    /// Entfernt, was sich entfernen lässt. Ein Setup, das noch läuft, hält seinen Ordner fest; der bleibt dann
    /// bis zum nächsten Start liegen, alles andere verschwindet trotzdem.
    /// </summary>
    internal static void Cleanup(string root)
    {
        if (!Directory.Exists(root))
            return;
        foreach (var entry in Directory.GetFileSystemEntries(root))
        {
            try
            {
                if (Directory.Exists(entry))
                    Directory.Delete(entry, recursive: true);
                else
                    File.Delete(entry);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
            }
        }
        try
        {
            Directory.Delete(root);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
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
        [JsonPropertyName("tag_name")] public string? TagName { get; set; }
        [JsonPropertyName("html_url")] public string? HtmlUrl { get; set; }
        [JsonPropertyName("draft")] public bool Draft { get; set; }
        [JsonPropertyName("prerelease")] public bool Prerelease { get; set; }
        [JsonPropertyName("assets")] public GiteaAsset?[]? Assets { get; set; }
    }

    private sealed class GiteaAsset
    {
        [JsonPropertyName("name")] public string? Name { get; set; }
        [JsonPropertyName("browser_download_url")] public string? BrowserDownloadUrl { get; set; }
    }
}

public sealed record UpdateInfo(Version Version, string ReleaseUrl, string? SetupUrl, string? SetupName, string? ChecksumUrl);
