using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace WidgetTea.Tests;

/// <summary>
/// Abfrage und Download des Updaters über einen nachgestellten Transport: was als Update gilt, dass ohne passende
/// Prüfsumme nichts auf der Platte bleibt und dass ein festgehaltenes Setup den nächsten Download nicht blockiert.
/// </summary>
public sealed class UpdateServiceTransportTests : IDisposable
{
    private const string Repository = "https://github.com/Celestial0579/WidgetTea";
    private static readonly Version Running = new(1, 1, 0);
    private static readonly byte[] Setup = Encoding.ASCII.GetBytes("das ist das Setup");

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private readonly string _root = Path.Combine(Path.GetTempPath(), "widgettea-test-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_root))
                Directory.Delete(_root, recursive: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        public List<string> Requested { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requested.Add(request.RequestUri!.AbsoluteUri);
            return Task.FromResult(respond(request));
        }
    }

    private static HttpResponseMessage Json(string body) =>
        new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    private static string Sha256(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();

    private static UpdateInfo Offer(string setupName = "WidgetTea-9.9.9-setup.exe", string? checksumUrl = "https://example.invalid/setup.exe.sha256") =>
        new(new Version(9, 9, 9), "https://example.invalid/release", "https://example.invalid/setup.exe", setupName, checksumUrl);

    /// <summary>Ein Dienst, dessen „Server“ das Setup liefert und als Prüfsumme die angegebene Zeile.</summary>
    private UpdateService Downloading(string checksumLine, out StubHandler handler)
    {
        handler = new StubHandler(request => request.RequestUri!.AbsoluteUri.EndsWith(".sha256", StringComparison.Ordinal)
            ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(checksumLine) }
            : new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Setup) });
        return new UpdateService(null, handler) { DownloadRoot = _root };
    }

    // ---- Abfrage

    private static string Release(string tag, bool draft = false, bool prerelease = false, string assets = """
        {"name": "WidgetTea-1.2.0-setup.exe", "browser_download_url": "https://example.invalid/dl/setup.exe"},
        {"name": "WidgetTea-1.2.0-setup.exe.sha256", "browser_download_url": "https://example.invalid/dl/setup.exe.sha256"}
        """) => $$"""
        {"tag_name": "{{tag}}", "html_url": "https://example.invalid/release", "draft": {{(draft ? "true" : "false")}},
         "prerelease": {{(prerelease ? "true" : "false")}}, "assets": [ {{assets}} ]}
        """;

    [Fact]
    public async Task Ein_neueres_Release_wird_mit_Setup_und_Pruefsumme_angeboten()
    {
        var handler = new StubHandler(_ => Json(Release("v1.2.0")));

        var info = await new UpdateService(null, handler).CheckAsync(Repository, Running, Ct);

        Assert.NotNull(info);
        Assert.Equal(new Version(1, 2, 0), info.Version);
        Assert.Equal("WidgetTea-1.2.0-setup.exe", info.SetupName);
        Assert.Equal("https://example.invalid/dl/setup.exe", info.SetupUrl);
        Assert.Equal("https://example.invalid/dl/setup.exe.sha256", info.ChecksumUrl);
        Assert.Equal(["https://api.github.com/repos/Celestial0579/WidgetTea/releases/latest"], handler.Requested);
    }

    [Theory]
    [InlineData("v1.1.0", false, false)]        // dieselbe Version
    [InlineData("v1.0.0", false, false)]        // älter: kein Rückschritt
    [InlineData("v1.2.0", true, false)]         // Entwurf
    [InlineData("v1.2.0", false, true)]         // Vorabversion
    [InlineData("v1.2.0-beta", false, false)]
    [InlineData("neueste", false, false)]
    public async Task Was_kein_neueres_fertiges_Release_ist_wird_nicht_angeboten(string tag, bool draft, bool prerelease)
    {
        var handler = new StubHandler(_ => Json(Release(tag, draft, prerelease)));

        Assert.Null(await new UpdateService(null, handler).CheckAsync(Repository, Running, Ct));
    }

    [Fact]
    public async Task Ohne_Release_gibt_es_kein_Angebot()
    {
        var handler = new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.NotFound));

        Assert.Null(await new UpdateService(null, handler).CheckAsync(Repository, Running, Ct));
    }

    [Fact]
    public async Task Fehlt_die_Pruefsumme_im_Release_wird_nichts_geladen()
    {
        var onlySetup = """{"name": "WidgetTea-1.2.0-setup.exe", "browser_download_url": "https://example.invalid/dl/setup.exe"}""";
        var handler = new StubHandler(_ => Json(Release("v1.2.0", assets: onlySetup)));
        var service = new UpdateService(null, handler) { DownloadRoot = _root };

        var info = await service.CheckAsync(Repository, Running, Ct);
        Assert.NotNull(info);
        Assert.Null(info.ChecksumUrl);

        await Assert.ThrowsAsync<InvalidOperationException>(() => service.DownloadAsync(info, Ct));
        Assert.Single(handler.Requested);            // nur die Abfrage, kein Download
        Assert.False(Directory.Exists(_root));
    }

    // ---- Download

    [Fact]
    public async Task Setup_mit_passender_Pruefsumme_liegt_danach_in_einem_eigenen_Ordner()
    {
        var service = Downloading(Sha256(Setup) + "  WidgetTea-9.9.9-setup.exe", out _);

        var path = await service.DownloadAsync(Offer(), Ct);

        Assert.Equal(Setup, File.ReadAllBytes(path));
        Assert.Equal("WidgetTea-9.9.9-setup.exe", Path.GetFileName(path));
        var folder = Path.GetDirectoryName(path)!;
        Assert.Equal(Path.GetFullPath(_root), Path.GetFullPath(Path.GetDirectoryName(folder)!));
        Assert.Matches("^[0-9a-f]{32}$", Path.GetFileName(folder));
    }

    [Fact]
    public async Task Ein_festgehaltenes_Setup_blockiert_den_naechsten_Download_nicht()
    {
        // So hält das Setup eines abgebrochenen Selbst-Updates seine Datei fest, solange sein Hinweis offen ist.
        var service = Downloading(Sha256(Setup), out _);
        var first = await service.DownloadAsync(Offer(), Ct);

        using (new FileStream(first, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            var second = await service.DownloadAsync(Offer(), Ct);

            Assert.NotEqual(first, second);
            Assert.Equal(Setup, File.ReadAllBytes(second));
        }
    }

    [Fact]
    public async Task Bei_falscher_Pruefsumme_bleibt_nichts_liegen()
    {
        var service = Downloading(Sha256(Encoding.ASCII.GetBytes("etwas anderes")), out _);

        await Assert.ThrowsAsync<InvalidOperationException>(() => service.DownloadAsync(Offer(), Ct));

        Assert.Empty(Directory.GetFileSystemEntries(_root));
    }

    [Fact]
    public async Task Ein_Name_mit_Pfadanteilen_fuehrt_nicht_aus_dem_Ordner_hinaus()
    {
        var service = Downloading(Sha256(Setup), out _);

        var path = await service.DownloadAsync(Offer(setupName: @"..\..\boese-setup.exe"), Ct);

        Assert.Equal("boese-setup.exe", Path.GetFileName(path));
        Assert.Equal(Path.GetFullPath(_root), Path.GetFullPath(Path.GetDirectoryName(Path.GetDirectoryName(path)!)!));
    }

    // ---- Aufräumen beim Start

    [Fact]
    public void Aufraeumen_entfernt_alles_bis_auf_das_was_noch_festgehalten_wird()
    {
        var held = Path.Combine(_root, "a", "laeuft-noch-setup.exe");
        var free = Path.Combine(_root, "b", "fertig-setup.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(held)!);
        Directory.CreateDirectory(Path.GetDirectoryName(free)!);
        File.WriteAllBytes(held, Setup);
        File.WriteAllBytes(free, Setup);
        File.WriteAllBytes(Path.Combine(_root, "altes-setup.exe"), Setup);   // so lag es bis 1.1.0 direkt im Ordner

        using (new FileStream(held, FileMode.Open, FileAccess.Read, FileShare.None))
        {
            UpdateService.Cleanup(_root);

            Assert.True(File.Exists(held));
            Assert.False(Directory.Exists(Path.GetDirectoryName(free)));
            Assert.False(File.Exists(Path.Combine(_root, "altes-setup.exe")));
        }

        UpdateService.Cleanup(_root);
        Assert.False(Directory.Exists(_root));
    }
}
