using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace WidgetTea;

/// <summary>Gitea hat geantwortet, aber nicht so, dass sich damit arbeiten lässt. Die Meldung ist für den Nutzer.</summary>
public class GiteaException(string message) : Exception(message);

public sealed class GiteaAuthException(string message) : GiteaException(message);

/// <summary>
/// Die Adresse antwortet mit Erfolg, aber nicht mit einer Heatmap: etwa die Anmeldeseite eines vorgeschalteten
/// Proxys, das Portal eines WLANs oder eine ganz andere Website.
/// </summary>
public sealed class GiteaResponseException(string message) : GiteaException(message);

public static class GiteaClient
{
    /// <summary>
    /// Holt /api/v1/users/{user}/heatmap und summiert die 15-Minuten-Buckets auf lokale Kalendertage.
    /// Wirft HttpRequestException/TaskCanceledException, wenn Gitea nicht erreichbar ist, und eine
    /// <see cref="GiteaException"/>, wenn die Antwort nicht zu gebrauchen ist.
    /// </summary>
    public static async Task<Dictionary<DateOnly, int>> FetchHeatmapAsync(AppSettings settings, string? token, CancellationToken ct)
    {
        using var handler = new HttpClientHandler();
        if (settings.IgnoreCertificateErrors)
            handler.ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator;
        return await FetchHeatmapAsync(settings, token, handler, ct);
    }

    /// <summary>Dasselbe über einen vorgegebenen Transport, damit sich die Auswertung der Antwort prüfen lässt.</summary>
    internal static async Task<Dictionary<DateOnly, int>> FetchHeatmapAsync(AppSettings settings, string? token, HttpMessageHandler handler, CancellationToken ct)
    {
        using var http = new HttpClient(handler, disposeHandler: false) { Timeout = TimeSpan.FromSeconds(settings.TimeoutSeconds) };
        var url = $"{settings.BaseUrl.TrimEnd('/')}/api/v1/users/{Uri.EscapeDataString(settings.Username)}/heatmap";
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (!string.IsNullOrEmpty(token))
            request.Headers.Authorization = new AuthenticationHeaderValue("token", token);

        using var response = await http.SendAsync(request, ct);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new GiteaAuthException("Token ungültig oder ohne Berechtigung");
        if (response.StatusCode == HttpStatusCode.NotFound)
            throw new GiteaAuthException($"Benutzer „{settings.Username}“ nicht gefunden");
        response.EnsureSuccessStatusCode();

        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        return await ParseHeatmapAsync(stream, ct);
    }

    /// <summary>
    /// Liest die Antwort von /heatmap: eine Liste aus Zeitstempel und Zahl der Beiträge. Alles andere, auch
    /// gültiges JSON in anderer Form, wird zu einer <see cref="GiteaResponseException"/>.
    /// </summary>
    internal static async Task<Dictionary<DateOnly, int>> ParseHeatmapAsync(Stream stream, CancellationToken ct)
    {
        try
        {
            using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: ct);

            var days = new Dictionary<DateOnly, int>();
            foreach (var entry in doc.RootElement.EnumerateArray())
            {
                long timestamp = entry.GetProperty("timestamp").GetInt64();
                int contributions = checked((int)entry.GetProperty("contributions").GetInt64());
                var day = DateOnly.FromDateTime(DateTimeOffset.FromUnixTimeSeconds(timestamp).LocalDateTime);
                days[day] = days.GetValueOrDefault(day) + contributions;
            }
            return days;
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or KeyNotFoundException
                                       or FormatException or ArgumentOutOfRangeException or OverflowException)
        {
            throw new GiteaResponseException("Adresse antwortet nicht wie ein Gitea");
        }
    }
}
