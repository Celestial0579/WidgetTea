using System;
using System.IO;
using Xunit;

namespace WidgetTea.Tests;

/// <summary>
/// Die Bremse gegen ein Selbst-Update, das immer wieder scheitert: Ohne sie lüde die alte Version dasselbe Update
/// eine Minute nach jedem Start erneut und schlösse sich dafür.
/// </summary>
public class UpdateAttemptTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 12, 12, 0, 0, TimeSpan.Zero);
    private static readonly Version Offered = new(1, 1, 0);

    private static UpdateAttempt Attempt(string version, double hoursAgo, int count) =>
        new() { Version = version, StartedAt = Now - TimeSpan.FromHours(hoursAgo), Count = count };

    [Fact]
    public void Ohne_Vermerk_wird_von_selbst_installiert()
    {
        Assert.True(UpdateAttempt.AllowsAutomatic(null, Offered, Now));
    }

    [Theory]
    [InlineData("1.0.5")]   // ein früheres Update, das nie ankam
    [InlineData("1.2.0")]
    [InlineData("kaputt")]
    [InlineData("")]
    public void Ein_Vermerk_fuer_eine_andere_Version_bremst_nicht(string version)
    {
        Assert.True(UpdateAttempt.AllowsAutomatic(Attempt(version, hoursAgo: 0.01, count: 3), Offered, Now));
    }

    [Theory]
    [InlineData(0.02, 1, false)]    // eine Minute nach dem Versuch: genau die Schleife, um die es geht
    [InlineData(23.9, 1, false)]
    [InlineData(24, 1, true)]
    [InlineData(100, 2, true)]
    [InlineData(100, 3, false)]     // dreimal gescheitert: nur noch von Hand
    [InlineData(10000, 7, false)]
    public void Dieselbe_Version_erst_nach_einem_Tag_und_hoechstens_dreimal(double hoursAgo, int count, bool expected)
    {
        Assert.Equal(expected, UpdateAttempt.AllowsAutomatic(Attempt("1.1.0", hoursAgo, count), Offered, Now));
    }

    [Fact]
    public void Eine_verstellte_Uhr_sperrt_nicht_auf_Dauer()
    {
        Assert.True(UpdateAttempt.AllowsAutomatic(Attempt("1.1.0", hoursAgo: -500, count: 1), Offered, Now));
    }

    [Fact]
    public void Der_Vermerk_zaehlt_Versuche_derselben_Version()
    {
        var first = UpdateAttempt.Next(null, Offered, Now);
        var second = UpdateAttempt.Next(first, Offered, Now.AddDays(1));
        var other = UpdateAttempt.Next(second, new Version(1, 2, 0), Now.AddDays(2));

        Assert.Equal(("1.1.0", 1, Now), (first.Version, first.Count, first.StartedAt));
        Assert.Equal(("1.1.0", 2, Now.AddDays(1)), (second.Version, second.Count, second.StartedAt));
        Assert.Equal(("1.2.0", 1), (other.Version, other.Count));
    }

    [Theory]
    [InlineData("1.1.0", "1.0.0", false)]   // noch die alte Version: Das Update ist nicht angekommen
    [InlineData("1.1.0", "1.1.0", true)]
    [InlineData("1.1.0", "1.2.0", true)]
    [InlineData("kaputt", "1.0.0", true)]
    public void Erledigt_ist_der_Vermerk_wenn_die_Version_laeuft(string attempted, string running, bool expected)
    {
        Assert.Equal(expected, UpdateAttempt.IsSettled(Attempt(attempted, 1, 1), Version.Parse(running)));
    }

    [Fact]
    public void Der_Vermerk_uebersteht_einen_Neustart()
    {
        var folder = Path.Combine(Path.GetTempPath(), "widgettea-test-" + Guid.NewGuid().ToString("N"));
        var file = Path.Combine(folder, "update-attempt.json");
        try
        {
            Assert.Null(UpdateAttempt.Load(file));

            UpdateAttempt.Next(null, Offered, Now).Save(file);
            var loaded = UpdateAttempt.Load(file);
            Assert.NotNull(loaded);
            Assert.Equal(("1.1.0", 1, Now), (loaded.Version, loaded.Count, loaded.StartedAt));
            // Eine Minute später, nach dem Neustart der alten Version: nicht noch einmal.
            Assert.False(UpdateAttempt.AllowsAutomatic(loaded, Offered, Now.AddMinutes(1)));

            File.WriteAllText(file, "kein JSON");
            Assert.Null(UpdateAttempt.Load(file));

            UpdateAttempt.Clear(file);
            Assert.False(File.Exists(file));
            UpdateAttempt.Clear(file);   // zweimal schadet nicht
        }
        finally
        {
            if (Directory.Exists(folder))
                Directory.Delete(folder, recursive: true);
        }
    }
}
