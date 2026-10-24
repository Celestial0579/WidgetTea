using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace WidgetTea;

public sealed class GiteaAuthException(string message) : Exception(message);

public static class GiteaClient
{
    /// <summary>
    /// Holt /api/v1/users/{user}/heatmap und summiert die 15-Minuten-Buckets auf lokale Kalendertage.
    /// Wirft HttpRequestException/TaskCanceledException, wenn Gitea nicht erreichbar ist.
    /// </summary>
    public static async Task<Dictionary<DateOnly, int>> FetchHeatmapAsync(AppSettings settings, string? token, CancellationToken ct)
    {
        using var handler = new HttpClientHandler();
        if (settings.IgnoreCertificateErrors)
            handler.ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator;

        using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(settings.TimeoutSeconds) };
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
        using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: ct);

        var days = new Dictionary<DateOnly, int>();
        foreach (var entry in doc.RootElement.EnumerateArray())
        {
            long timestamp = entry.GetProperty("timestamp").GetInt64();
            int contributions = (int)entry.GetProperty("contributions").GetInt64();
            var day = DateOnly.FromDateTime(DateTimeOffset.FromUnixTimeSeconds(timestamp).LocalDateTime);
            days[day] = days.GetValueOrDefault(day) + contributions;
        }
        return days;
    }
}
