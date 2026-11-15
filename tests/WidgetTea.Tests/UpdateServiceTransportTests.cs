using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
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
        {"name": "WidgetTea-1.2.0-setup.exe", "browser_download_url": "https://github.com/Celestial0579/WidgetTea/releases/download/v1.2.0/WidgetTea-1.2.0-setup.exe"},
        {"name": "WidgetTea-1.2.0-setup.exe.sha256", "browser_download_url": "https://github.com/Celestial0579/WidgetTea/releases/download/v1.2.0/WidgetTea-1.2.0-setup.exe.sha256"}
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
        Assert.Equal("https://github.com/Celestial0579/WidgetTea/releases/download/v1.2.0/WidgetTea-1.2.0-setup.exe", info.SetupUrl);
        Assert.Equal("https://github.com/Celestial0579/WidgetTea/releases/download/v1.2.0/WidgetTea-1.2.0-setup.exe.sha256", info.ChecksumUrl);
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
        var onlySetup = """{"name": "WidgetTea-1.2.0-setup.exe", "browser_download_url": "https://github.com/Celestial0579/WidgetTea/releases/download/v1.2.0/WidgetTea-1.2.0-setup.exe"}""";
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

    // ---- Herkunft der Dateien, unvollständige Antworten (Issue 35)

    [Theory]
    [InlineData("http://github.com/Celestial0579/WidgetTea/releases/download/v1.2.0/x")]          // kein https
    [InlineData("https://example.invalid/Celestial0579/WidgetTea/releases/download/v1.2.0/x")]    // anderer Host
    [InlineData("https://github.com/jemand/anderes/releases/download/v1.2.0/x")]                   // anderes Repo
    [InlineData("https://github.com/Celestial0579/WidgetTea/archive/x")]                           // kein Release
    [InlineData("https://github.com/Celestial0579/WidgetTea/releases/download/")]                  // nur das Präfix
    [InlineData("https://github.com/Celestial0579/WidgetTea/releases/download/../../../jemand/x")] // hinaus
    [InlineData("https://user@github.com/Celestial0579/WidgetTea/releases/download/v1.2.0/x")]     // Anmeldeteil
    [InlineData("https://github.com:8443/Celestial0579/WidgetTea/releases/download/v1.2.0/x")]     // anderer Port
    [InlineData("kein-uri")]
    [InlineData(null)]
    public void Fremde_Download_Adressen_gelten_nicht(string? url)
    {
        Assert.False(UpdateService.IsReleaseDownload(url, Repository));
    }

    [Fact]
    public void Bei_einem_Repo_ueber_http_gilt_https_nicht_als_dasselbe()
    {
        Assert.False(UpdateService.IsReleaseDownload("https://gitea.example.com/owner/repo/releases/download/v1/x.exe", "http://gitea.example.com/owner/repo"));
        Assert.False(UpdateService.IsReleaseDownload("ftp://gitea.example.com/owner/repo/releases/download/v1/x.exe", "ftp://gitea.example.com/owner/repo"));
    }

    [Theory]
    [InlineData("https://github.com/Celestial0579/WidgetTea", "https://github.com/Celestial0579/WidgetTea/releases/download/v1.2.0/WidgetTea-1.2.0-setup.exe")]
    [InlineData("https://github.com/celestial0579/widgettea/", "https://GitHub.com/Celestial0579/WidgetTea/releases/download/v1.2.0/x.exe")]
    [InlineData("https://gitea.example.com/sub/owner/repo", "https://gitea.example.com/sub/owner/repo/releases/download/v1/x.exe")]
    [InlineData("http://127.0.0.1:8080/owner/repo", "http://127.0.0.1:8080/owner/repo/releases/download/v1/x.exe")]   // Gitea nur über http
    public void Dateien_aus_den_Releases_des_Update_Repos_gelten(string repository, string url)
    {
        Assert.True(UpdateService.IsReleaseDownload(url, repository));
    }

    [Fact]
    public async Task Ein_Release_mit_Dateien_von_anderswo_bietet_nichts_zum_Laden_an()
    {
        var foreign = """
            {"name": "WidgetTea-1.2.0-setup.exe", "browser_download_url": "https://example.invalid/dl/setup.exe"},
            {"name": "WidgetTea-1.2.0-setup.exe.sha256", "browser_download_url": "http://github.com/Celestial0579/WidgetTea/releases/download/v1.2.0/WidgetTea-1.2.0-setup.exe.sha256"}
            """;
        var handler = new StubHandler(_ => Json(Release("v1.2.0", assets: foreign)));
        var service = new UpdateService(null, handler) { DownloadRoot = _root };

        var info = await service.CheckAsync(Repository, Running, Ct);

        Assert.NotNull(info);
        Assert.Null(info.SetupUrl);
        Assert.Null(info.ChecksumUrl);
        await Assert.ThrowsAsync<InvalidOperationException>(() => service.DownloadAsync(info, Ct));
        Assert.Single(handler.Requested);            // nur die Abfrage, kein Download
    }

    [Theory]
    [InlineData("""{"tag_name": "v1.2.0", "assets": null}""")]
    [InlineData("""{"tag_name": "v1.2.0"}""")]
    [InlineData("""{"tag_name": "v1.2.0", "html_url": null, "assets": [null, {"name": null, "browser_download_url": null}, {}]}""")]
    [InlineData("""{"tag_name": null, "assets": []}""")]
    public async Task Eine_unvollstaendige_Antwort_ist_kein_Fehler(string body)
    {
        var handler = new StubHandler(_ => Json(body));

        var info = await new UpdateService(null, handler).CheckAsync(Repository, Running, Ct);

        Assert.True(info == null || info.SetupUrl == null);
    }

    [Fact]
    public async Task Das_Token_geht_nur_an_den_Host_des_Update_Repos()
    {
        const string gitea = "https://gitea.example.com/owner/repo";
        var seen = new List<(string Url, string? Auth)>();
        var handler = new StubHandler(request =>
        {
            seen.Add((request.RequestUri!.AbsoluteUri, request.Headers.Authorization?.ToString()));
            return request.RequestUri!.AbsoluteUri.EndsWith(".sha256", StringComparison.Ordinal)
                ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(Sha256(Setup)) }
                : new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Setup) };
        });
        var service = new UpdateService("geheim", handler, gitea) { DownloadRoot = _root };

        await service.DownloadAsync(new UpdateInfo(new Version(9, 9, 9), gitea, "https://gitea.example.com/owner/repo/releases/download/v9/s.exe",
            "s.exe", "https://anderer.example.com/s.exe.sha256"), Ct);

        Assert.Equal(2, seen.Count);
        Assert.Equal("token geheim", seen.Single(r => r.Url.StartsWith("https://gitea.example.com/", StringComparison.Ordinal)).Auth);
        Assert.Null(seen.Single(r => r.Url.StartsWith("https://anderer.example.com/", StringComparison.Ordinal)).Auth);
    }

    // ---- Größengrenzen (Issue 35)

    /// <summary>Liefert beliebig viele Nullbytes, ohne die Länge anzukündigen.</summary>
    private sealed class EndlessStream(long length) : Stream
    {
        private long _left = length;
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count)
        {
            var n = (int)Math.Min(count, _left);
            Array.Clear(buffer, offset, n);
            _left -= n;
            return n;
        }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    [Fact]
    public async Task Eine_zu_grosse_Pruefsummen_Datei_wird_verworfen()
    {
        var service = Downloading(new string('a', 4096), out var handler);

        await Assert.ThrowsAsync<InvalidOperationException>(() => service.DownloadAsync(Offer(), Ct));

        Assert.Single(handler.Requested);            // das Setup wird gar nicht erst geladen
    }

    [Theory]
    [InlineData(true)]    // Länge angekündigt
    [InlineData(false)]   // Länge nicht angekündigt, der Strom hört nicht auf
    public async Task Ein_zu_grosses_Setup_wird_verworfen_und_nichts_bleibt_liegen(bool announced)
    {
        var handler = new StubHandler(request =>
        {
            if (request.RequestUri!.AbsoluteUri.EndsWith(".sha256", StringComparison.Ordinal))
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(Sha256(Setup)) };
            var content = new StreamContent(new EndlessStream(UpdateService.MaxSetupBytes + 1));
            content.Headers.ContentLength = announced ? UpdateService.MaxSetupBytes + 1 : null;
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
        });
        var service = new UpdateService(null, handler) { DownloadRoot = _root };

        await Assert.ThrowsAsync<InvalidOperationException>(() => service.DownloadAsync(Offer(), Ct));

        Assert.Empty(Directory.GetFileSystemEntries(_root));
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
