using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace WidgetTea;

public sealed class HeatmapCache
{
    private static string FilePath => AppPaths.CacheFile;

    public string Username { get; set; } = "";
    public string BaseUrl { get; set; } = "";
    public DateTimeOffset LastSync { get; set; }
    public Dictionary<DateOnly, int> Days { get; set; } = new();

    public static HeatmapCache? Load()
    {
        try
        {
            return File.Exists(FilePath)
                ? JsonSerializer.Deserialize<HeatmapCache>(File.ReadAllText(FilePath))
                : null;
        }
        catch (Exception ex) when (ex is JsonException or IOException)
        {
            return null;
        }
    }

    public bool Matches(AppSettings settings) =>
        string.Equals(Username, settings.Username, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(BaseUrl.TrimEnd('/'), settings.BaseUrl.TrimEnd('/'), StringComparison.OrdinalIgnoreCase);

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        var tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this));
        File.Move(tmp, FilePath, overwrite: true);
    }
}
