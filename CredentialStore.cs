using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace WidgetTea;

/// <summary>
/// Speichert das Gitea-Token DPAPI-verschlüsselt (nur für den aktuellen Windows-Benutzer lesbar),
/// getrennt von den Einstellungen in %LOCALAPPDATA%\WidgetTea\credentials.bin. Das Token wird nur
/// über das Einstellungsfenster gesetzt und nie im Klartext auf die Platte geschrieben.
/// </summary>
public static class CredentialStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("WidgetTea.Tokens.v1");

    public static bool HasToken => File.Exists(AppPaths.CredentialsFile);

    public static void Save(string token)
    {
        Directory.CreateDirectory(AppPaths.Root);
        var tmp = AppPaths.CredentialsFile + ".tmp";
        File.WriteAllBytes(tmp, ProtectedData.Protect(Encoding.UTF8.GetBytes(token), Entropy, DataProtectionScope.CurrentUser));
        File.Move(tmp, AppPaths.CredentialsFile, overwrite: true);
    }

    public static string? Load()
    {
        try
        {
            if (!HasToken)
                return null;
            var plain = ProtectedData.Unprotect(File.ReadAllBytes(AppPaths.CredentialsFile), Entropy, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }
        catch (Exception ex) when (ex is CryptographicException or IOException)
        {
            // z.B. anderes Windows-Konto – Token muss neu eingegeben werden.
            return null;
        }
    }

    public static void Clear() => File.Delete(AppPaths.CredentialsFile);
}
