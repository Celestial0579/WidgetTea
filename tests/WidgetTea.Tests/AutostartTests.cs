using Xunit;

namespace WidgetTea.Tests;

/// <summary>
/// Wie die App den Schalter unter „Autostart-Apps“ bzw. im Task-Manager liest (Issue 43, C12): Windows lässt den
/// Run-Wert stehen und vermerkt unter StartupApproved\Run, ob er gilt.
/// </summary>
public class AutostartTests
{
    [Theory]
    [InlineData(null, false)]                                                   // kein Vermerk: gilt
    [InlineData(new byte[0], false)]
    [InlineData(new byte[] { 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, false)]     // im Task-Manager eingeschaltet
    [InlineData(new byte[] { 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, false)]
    [InlineData(new byte[] { 3, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8 }, true)]      // abgeschaltet (mit Zeitpunkt)
    [InlineData(new byte[] { 1 }, true)]
    [InlineData(new byte[] { 7, 0, 0, 0 }, true)]
    public void Ein_ungerades_erstes_Byte_heisst_abgeschaltet(byte[]? approved, bool disabled)
    {
        Assert.Equal(disabled, Autostart.IsDisabledByWindows(approved));
    }
}
