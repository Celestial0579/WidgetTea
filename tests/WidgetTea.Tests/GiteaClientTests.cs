using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace WidgetTea.Tests;

/// <summary>
/// Was GiteaClient aus einer Antwort macht. Wichtig ist vor allem der Fall, dass die Adresse antwortet, aber nicht
/// als Gitea: Das muss als Meldung beim Nutzer ankommen und darf keine Ausnahme sein, die niemand fängt.
/// </summary>
public class GiteaClientTests
{
    private const long Noon = 1762948800;         // 12.11.2025, 12:00 UTC
    private const long NoonNextDay = 1763035200;

    private static readonly AppSettings Settings = new()
    {
        BaseUrl = "https://gitea.example.com/",
        Username = "Jörg Müller",
        TimeoutSeconds = 10,
    };

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public List<HttpRequestMessage> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(request);
            return Task.FromResult(respond(request));
        }
    }

    private static StubHandler Replying(HttpStatusCode status, string body, string mediaType = "application/json") =>
        new(_ => new HttpResponseMessage(status) { Content = new StringContent(body, Encoding.UTF8, mediaType) });

    private static Stream Body(string text) => new MemoryStream(Encoding.UTF8.GetBytes(text));

    private static DateOnly LocalDay(long timestamp) =>
        DateOnly.FromDateTime(DateTimeOffset.FromUnixTimeSeconds(timestamp).LocalDateTime);

    [Fact]
    public async Task Beitraege_werden_je_Tag_summiert()
    {
        var json = $$"""
            [ {"timestamp": {{Noon}}, "contributions": 2},
              {"timestamp": {{Noon + 900}}, "contributions": 3},
              {"timestamp": {{NoonNextDay}}, "contributions": 1} ]
            """;

        var days = await GiteaClient.ParseHeatmapAsync(Body(json), CancellationToken.None);

        Assert.Equal(2, days.Count);
        Assert.Equal(5, days[LocalDay(Noon)]);
        Assert.Equal(1, days[LocalDay(NoonNextDay)]);
    }

    [Fact]
    public async Task Leere_Liste_ergibt_keine_Tage()
    {
        Assert.Empty(await GiteaClient.ParseHeatmapAsync(Body("[]"), CancellationToken.None));
    }

    [Theory]
    [InlineData("<!DOCTYPE html><html><body>Bitte anmelden</body></html>")]
    [InlineData("")]
    [InlineData("{\"message\": \"Not Found\"}")]
    [InlineData("[1, 2, 3]")]
    [InlineData("[{\"contributions\": 1}]")]
    [InlineData("[{\"timestamp\": \"gestern\", \"contributions\": 1}]")]
    [InlineData("[{\"timestamp\": 1762948800, \"contributions\": 99999999999}]")]
    [InlineData("[{\"timestamp\": 99999999999999999, \"contributions\": 1}]")]
    public async Task Was_keine_Heatmap_ist_wird_als_solches_gemeldet(string body)
    {
        var ex = await Assert.ThrowsAsync<GiteaResponseException>(
            () => GiteaClient.ParseHeatmapAsync(Body(body), CancellationToken.None));

        Assert.False(string.IsNullOrWhiteSpace(ex.Message));
    }

    [Fact]
    public async Task Abruf_fragt_die_Heatmap_des_Benutzers_und_schickt_das_Token()
    {
        var handler = Replying(HttpStatusCode.OK, "[]");

        await GiteaClient.FetchHeatmapAsync(Settings, "geheim", handler, CancellationToken.None);

        var request = Assert.Single(handler.Requests);
        Assert.Equal("https://gitea.example.com/api/v1/users/J%C3%B6rg%20M%C3%BCller/heatmap", request.RequestUri!.AbsoluteUri);
        Assert.Equal("token", request.Headers.Authorization!.Scheme);
        Assert.Equal("geheim", request.Headers.Authorization.Parameter);
    }

    [Fact]
    public async Task Ohne_Token_geht_keine_Anmeldung_mit()
    {
        var handler = Replying(HttpStatusCode.OK, "[]");

        await GiteaClient.FetchHeatmapAsync(Settings, null, handler, CancellationToken.None);

        Assert.Null(Assert.Single(handler.Requests).Headers.Authorization);
    }

    [Fact]
    public async Task Anmeldeseite_statt_JSON_ist_eine_Meldung_fuer_den_Nutzer()
    {
        // Ein Proxy vor Gitea, das Portal eines WLANs: Status 200, aber HTML. Genau das brachte „Verbindung testen“
        // zum Absturz, solange niemand die JsonException fing.
        var handler = Replying(HttpStatusCode.OK, "<!DOCTYPE html><html><body>Bitte anmelden</body></html>", "text/html");

        var ex = await Assert.ThrowsAsync<GiteaResponseException>(
            () => GiteaClient.FetchHeatmapAsync(Settings, "geheim", handler, CancellationToken.None));

        // Beide Fenster fangen GiteaException und zeigen deren Meldung.
        Assert.IsAssignableFrom<GiteaException>(ex);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Forbidden)]
    [InlineData(HttpStatusCode.NotFound)]
    public async Task Abgelehnt_oder_unbekannt_ist_eine_Meldung_fuer_den_Nutzer(HttpStatusCode status)
    {
        var handler = Replying(status, "{}");

        var ex = await Assert.ThrowsAsync<GiteaAuthException>(
            () => GiteaClient.FetchHeatmapAsync(Settings, "geheim", handler, CancellationToken.None));

        Assert.IsAssignableFrom<GiteaException>(ex);
    }

    [Fact]
    public async Task Serverfehler_bleibt_ein_Netzfehler()
    {
        var handler = Replying(HttpStatusCode.InternalServerError, "kaputt", "text/plain");

        await Assert.ThrowsAsync<HttpRequestException>(
            () => GiteaClient.FetchHeatmapAsync(Settings, "geheim", handler, CancellationToken.None));
    }
}
