using System;
using Xunit;

namespace WidgetTea.Tests;

/// <summary>
/// Die beiden reinen Funktionen des Updaters: Welche Tags gelten als Version, und welche Adresse wird
/// für „neuestes Release“ gefragt. Beides entscheidet, ob ein Selbst-Update überhaupt stattfindet.
/// </summary>
public class UpdateServiceTests
{
    [Theory]
    [InlineData("v1.2.3", 1, 2, 3)]
    [InlineData("1.2.3", 1, 2, 3)]
    [InlineData("V2.0", 2, 0, 0)]
    [InlineData("v3", 3, 0, 0)]
    [InlineData("  v1.10.0  ", 1, 10, 0)]
    [InlineData("1.2.3.4", 1, 2, 3)]
    public void TryParseVersion_liest_Versions_Tags(string tag, int major, int minor, int build)
    {
        Assert.True(UpdateService.TryParseVersion(tag, out var version));
        Assert.Equal(new Version(major, minor, build), version);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("v")]
    [InlineData("neueste")]
    [InlineData("1.2.x")]
    public void TryParseVersion_lehnt_ab_was_keine_Version_ist(string? tag)
    {
        Assert.False(UpdateService.TryParseVersion(tag, out _));
    }

    [Theory]
    [InlineData("v1.2.0-beta")]
    [InlineData("1.2.0-rc.1")]
    [InlineData("v1.2.0+build5")]
    public void TryParseVersion_bietet_Vorabversionen_nie_an(string tag)
    {
        Assert.False(UpdateService.TryParseVersion(tag, out _));
    }

    [Fact]
    public void Eine_Version_ohne_dritte_Stelle_ist_nicht_neuer_als_dieselbe_mit_Null()
    {
        // Version("2.0") hat Build -1 und wäre sonst kleiner als 2.0.0 – der Vergleich im Updater ginge schief.
        Assert.True(UpdateService.TryParseVersion("v2.0", out var kurz));
        Assert.True(UpdateService.TryParseVersion("v2.0.0", out var lang));
        Assert.Equal(lang, kurz);
    }

    [Theory]
    [InlineData("https://github.com/Celestial0579/WidgetTea",
        "https://api.github.com/repos/Celestial0579/WidgetTea/releases/latest")]
    [InlineData("https://github.com/Celestial0579/WidgetTea/",
        "https://api.github.com/repos/Celestial0579/WidgetTea/releases/latest")]
    [InlineData("https://GitHub.com/Celestial0579/WidgetTea",
        "https://api.github.com/repos/Celestial0579/WidgetTea/releases/latest")]
    public void LatestReleaseApi_fragt_bei_GitHub_die_GitHub_API(string repository, string expected)
    {
        Assert.Equal(expected, UpdateService.LatestReleaseApi(repository));
    }

    [Theory]
    [InlineData("https://git.example.com/tim/WidgetTea",
        "https://git.example.com/api/v1/repos/tim/WidgetTea/releases/latest")]
    [InlineData("https://example.com/gitea/tim/WidgetTea",
        "https://example.com/gitea/api/v1/repos/tim/WidgetTea/releases/latest")]
    [InlineData("http://gitea.firma.local:3000/tim/WidgetTea/",
        "http://gitea.firma.local:3000/api/v1/repos/tim/WidgetTea/releases/latest")]
    public void LatestReleaseApi_fragt_sonst_die_Gitea_API_auch_unter_einem_Unterpfad(string repository, string expected)
    {
        Assert.Equal(expected, UpdateService.LatestReleaseApi(repository));
    }
}
