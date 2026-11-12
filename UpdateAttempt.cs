using System;
using System.IO;
using System.Text.Json;

namespace WidgetTea;

/// <summary>
/// Vermerk über ein begonnenes Selbst-Update. Die App beendet sich, bevor das Setup läuft, und erfährt nicht, was
/// daraus wird. Scheitert das Setup, läuft nach dem nächsten Start noch die alte Version – ohne diesen Vermerk
/// lüde sie dasselbe Update eine Minute später erneut und schlösse sich wieder, bei jedem Start.
/// </summary>
public sealed class UpdateAttempt
{
    /// <summary>So lange wartet die App, bevor sie dieselbe Version noch einmal von selbst installiert.</summary>
    internal static readonly TimeSpan RetryAfter = TimeSpan.FromHours(24);

    /// <summary>Danach installiert sie diese Version nur noch auf Wunsch des Nutzers.</summary>
    internal const int MaxAutomatic = 3;

    public string Version { get; set; } = "";
    public DateTimeOffset StartedAt { get; set; }
    public int Count { get; set; }

    /// <summary>
    /// Darf die angebotene Version jetzt von selbst installiert werden? Ja, solange es für genau diese Version
    /// keinen Vermerk gibt. Sonst erst nach <see cref="RetryAfter"/> und höchstens <see cref="MaxAutomatic"/> Mal.
    /// </summary>
    internal static bool AllowsAutomatic(UpdateAttempt? last, Version offered, DateTimeOffset now)
    {
        if (last == null || !System.Version.TryParse(last.Version, out var tried) || tried != offered)
            return true;
        if (last.Count >= MaxAutomatic)
            return false;
        // Steht die Uhr vor dem Vermerk, wurde sie verstellt; dann nicht ewig warten.
        return now < last.StartedAt || now - last.StartedAt >= RetryAfter;
    }

    /// <summary>Der Vermerk für einen jetzt beginnenden Versuch; für dieselbe Version zählt er weiter.</summary>
    internal static UpdateAttempt Next(UpdateAttempt? last, Version version, DateTimeOffset now)
    {
        var text = version.ToString(3);
        return new UpdateAttempt
        {
            Version = text,
            StartedAt = now,
            Count = last != null && last.Version == text ? last.Count + 1 : 1,
        };
    }

    /// <summary>Ist der Vermerk erledigt, weil inzwischen die vermerkte Version läuft (oder eine neuere)?</summary>
    internal static bool IsSettled(UpdateAttempt attempt, Version running) =>
        !System.Version.TryParse(attempt.Version, out var tried) || tried <= running;

    public static UpdateAttempt? Load() => Load(AppPaths.UpdateAttemptFile);

    public void Save() => Save(AppPaths.UpdateAttemptFile);

    public static void Clear() => Clear(AppPaths.UpdateAttemptFile);

    internal static UpdateAttempt? Load(string path)
    {
        try
        {
            return File.Exists(path) ? JsonSerializer.Deserialize<UpdateAttempt>(File.ReadAllText(path)) : null;
        }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>Schreibt den Vermerk. Gelingt das nicht, findet das Update trotzdem statt – nur ohne Bremse.</summary>
    internal void Save(string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(this));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    internal static void Clear(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }
}
