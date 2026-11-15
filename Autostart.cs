using System;
using Microsoft.Win32;

namespace WidgetTea;

public static class Autostart
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "WidgetTea";

    /// <summary>
    /// Hier merkt sich Windows den Schalter unter „Autostart-Apps“ bzw. im Task-Manager. Der Run-Wert bleibt dabei
    /// stehen; ob er gilt, steht im ersten Byte dieses Werts (gerade: an, ungerade: abgeschaltet).
    /// </summary>
    private const string StartupApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";

    /// <summary>
    /// An ist der Autostart nur, wenn der Run-Wert da ist und Windows ihn nicht abgeschaltet hat. Wer ihn im
    /// Task-Manager abschaltet, sieht ihn deshalb auch im Einstellungsfenster als aus (Issue 43, C12).
    /// </summary>
    public static bool Enabled
    {
        get
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunKey);
            if (run?.GetValue(ValueName) is not string)
                return false;
            using var approved = Registry.CurrentUser.OpenSubKey(StartupApprovedKey);
            return !IsDisabledByWindows(approved?.GetValue(ValueName) as byte[]);
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value)
            {
                key.SetValue(ValueName, $"\"{Environment.ProcessPath}\"");
                // Schaltet der Nutzer den Autostart hier ausdrücklich ein, gilt das auch gegenüber einem früheren
                // Abschalten im Task-Manager. Ohne Vermerk behandelt Windows den Eintrag als eingeschaltet.
                using var approved = Registry.CurrentUser.OpenSubKey(StartupApprovedKey, writable: true);
                if (IsDisabledByWindows(approved?.GetValue(ValueName) as byte[]))
                    approved!.DeleteValue(ValueName, throwOnMissingValue: false);
            }
            else
                key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }

    /// <summary>Hat Windows den Autostart abgeschaltet? (erstes Byte ungerade, z.B. 03 statt 02)</summary>
    internal static bool IsDisabledByWindows(byte[]? approved) => approved is { Length: > 0 } && (approved[0] & 1) == 1;
}
