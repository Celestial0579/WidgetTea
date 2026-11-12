using Xunit;

namespace WidgetTea.Tests;

/// <summary>
/// Die Gitea-Adresse aus dem Einstellungsfenster: Sie geht an den Abruf, an die Shell (Link „Token in Gitea
/// erstellen“) und entscheidet, ob der Hinweis auf die unverschlüsselte Übertragung erscheint.
/// </summary>
public class AppSettingsTests
{
    [Theory]
    [InlineData("gitea.firma.local", "https://gitea.firma.local")]
    [InlineData("  https://gitea.firma.local/  ", "https://gitea.firma.local")]
    [InlineData("https://gitea.firma.local/api/v1", "https://gitea.firma.local")]
    [InlineData("https://gitea.firma.local/API/V1/", "https://gitea.firma.local")]
    [InlineData("http://192.168.1.5:3000", "http://192.168.1.5:3000")]
    [InlineData("https://firma.example/gitea", "https://firma.example/gitea")]
    public void Adresse_wird_in_Form_gebracht(string input, string expected)
    {
        Assert.True(AppSettings.TryNormalizeBaseUrl(input, out var url));
        Assert.Equal(expected, url);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("ftp://gitea.firma.local")]
    [InlineData("file:///C:/Windows/System32/calc.exe")]
    [InlineData("ms-settings://netzwerk")]
    public void Was_keine_http_Adresse_ist_wird_abgelehnt(string? input)
    {
        Assert.False(AppSettings.TryNormalizeBaseUrl(input, out _));
    }

    [Theory]
    [InlineData("http://gitea.firma.local", true)]
    [InlineData("HTTP://gitea.firma.local", true)]
    [InlineData("  http://192.168.1.5:3000/ ", true)]
    [InlineData("https://gitea.firma.local", false)]
    [InlineData("gitea.firma.local", false)]
    [InlineData("", false)]
    [InlineData("ftp://gitea.firma.local", false)]
    public void Nur_http_gilt_als_unverschluesselt(string input, bool expected)
    {
        Assert.Equal(expected, AppSettings.IsUnencrypted(input));
    }

    [Theory]
    [InlineData("https://gitea.firma.local", "tim", true)]
    [InlineData("http://gitea.firma.local", "tim", true)]
    [InlineData("https://gitea.firma.local", " ", false)]
    [InlineData("ftp://gitea.firma.local", "tim", false)]
    [InlineData("", "tim", false)]
    public void Vollstaendig_heisst_http_Adresse_und_Benutzername(string baseUrl, string username, bool expected)
    {
        Assert.Equal(expected, new AppSettings { BaseUrl = baseUrl, Username = username }.IsComplete);
    }
}
