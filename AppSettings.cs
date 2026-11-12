using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace WidgetTea;

public static class AppPaths
{
    public static readonly string Root = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WidgetTea");

    public static string SettingsFile => Path.Combine(Root, "settings.json");
    public static string CredentialsFile => Path.Combine(Root, "credentials.bin");
    public static string CacheFile => Path.Combine(Root, "cache.json");
}

/// <summary>Einstellungen ohne Geheimnisse – das Token liegt separat im <see cref="CredentialStore"/>.</summary>
public sealed class AppSettings
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    /// <summary>z.B. https://gitea.firma.local (ohne /api/v1)</summary>
    public string BaseUrl { get; set; } = "";
    public string Username { get; set; } = "";
    public int RefreshMinutes { get; set; } = 15;
    public int TimeoutSeconds { get; set; } = 10;

    /// <summary>Nur für interne CA ohne installiertes Root-Zertifikat.</summary>
    public bool IgnoreCertificateErrors { get; set; }

    /// <summary>Gefundene Updates ohne Rückfrage installieren.</summary>
    public bool AutoUpdate { get; set; } = true;

    public double? Left { get; set; }
    public double? Top { get; set; }
    public bool Locked { get; set; }

    public static bool Exists => File.Exists(AppPaths.SettingsFile);

    [JsonIgnore]
    public bool IsComplete => !string.IsNullOrWhiteSpace(Username) && IsHttpUrl(BaseUrl);

    /// <summary>
    /// Bringt eine eingegebene Gitea-Adresse in Form: ohne Leerraum, ohne Schrägstrich am Ende und ohne /api/v1;
    /// fehlt das Schema, wird https:// ergänzt. Falsch, wenn danach keine http- oder https-Adresse dasteht.
    /// </summary>
    public static bool TryNormalizeBaseUrl(string? input, out string url)
    {
        url = (input ?? "").Trim().TrimEnd('/');
        if (url.EndsWith("/api/v1", StringComparison.OrdinalIgnoreCase))
            url = url[..^"/api/v1".Length];
        if (url.Length == 0)
            return false;
        if (!url.Contains("://"))
            url = "https://" + url;
        return IsHttpUrl(url);
    }

    /// <summary>Wahr, wenn die Adresse unverschlüsselt ist: Das Token ginge dann im Klartext über das Netz.</summary>
    public static bool IsUnencrypted(string? input) =>
        TryNormalizeBaseUrl(input, out var url) && url.StartsWith("http://", StringComparison.OrdinalIgnoreCase);

    private static bool IsHttpUrl(string? url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri) &&
        (uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeHttp);

    public static AppSettings Load()
    {
        try
        {
            return Exists
                ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(AppPaths.SettingsFile), JsonOptions) ?? new()
                : new();
        }
        catch (Exception ex) when (ex is JsonException or IOException)
        {
            return new();
        }
    }

    public void Save()
    {
        Directory.CreateDirectory(AppPaths.Root);
        var tmp = AppPaths.SettingsFile + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, JsonOptions));
        File.Move(tmp, AppPaths.SettingsFile, overwrite: true);
    }
}
