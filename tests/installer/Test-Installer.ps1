<#
.SYNOPSIS
  Prüft das Setup still und ohne Zuschauer: Neuinstallation, Update von 1.0.0, Abbruch ohne passende
  .NET-Laufzeit und das abgelehnte Selbst-Update.

.DESCRIPTION
  Gedacht für die CI (windows-latest). Voraussetzung ist ein Lauf von build\release.ps1 ohne -Publish:
  Das Skript nimmt artifacts\<Version>\publish und das fertige Setup von dort.

  ACHTUNG: Das Skript installiert und deinstalliert WidgetTea für den angemeldeten Benutzer und schreibt
  dessen %LOCALAPPDATA%\WidgetTea\settings.json. Auf einem Rechner, auf dem WidgetTea benutzt wird, zerstört
  es Einstellungen. Außerhalb der CI läuft es deshalb nur mit -Force.

  Was geprüft wird:
    1  Neuinstallation mit /S, App startet mit der installierten .NET-Laufzeit, Deinstallation räumt auf.
    2  Das veröffentlichte Setup 1.0.0 (bringt die Laufzeit selbst mit) als Ausgangslage für das Update.
    3  /S ohne passende Laufzeit: Exitcode 3, an der vorhandenen Installation ändert sich kein Byte.
    4  /S /RESTART ohne passende Laufzeit, Nachfrage abgelehnt: Exitcode 3, Installation unberührt,
       „Updates automatisch installieren“ ist aus (sonst lüde die alte Version das Setup im Minutentakt neu).
    5  Update 1.0.0 → neu wie vom Updater (/S /RESTART): mitgebrachte Laufzeit entfernt, fremde Dateien im
       Ordner bleiben, App startet, automatische Updates sind wieder an.
    6  Dasselbe Ablehnen auf der neuen Fassung, danach hat „die App“ die Einstellungen neu gespeichert.
    7  Update neu → neu: nichts wird aufgeräumt, automatische Updates sind wieder an.
    8  /S /RESTART ohne passende Laufzeit, und niemand antwortet: Nach dem Zeitablauf läuft das Widget wieder,
       während der Hinweis noch auf dem Schirm steht; automatische Updates sind aus wie bei „Nein“.
    9  Deinstallation mit fremden Dateien im Ordner: Weg ist nur, was das Setup installiert hat.
   10  Fremde Programme neben dem Setup, die wie Hilfsprogramme von Windows heißen (cmd.exe, taskkill.exe, …),
       werden nicht ausgeführt. Als Gegenprobe startet das veröffentlichte 1.0.0 sie noch.
   11  Das Setup erkennt die laufende App an ihr selbst und nicht am Programmnamen: Ein fremdes Programm, das nur
       so heißt, läuft weiter; ein WidgetTea aus einem anderen Ordner wird beendet; lässt sich die App nicht
       beenden, gibt das Setup auf; die Deinstallation beendet die laufende App.
   12  Dateien, die in einer neuen Fassung wegfallen, verschwinden beim Update; fremde Dateien bleiben, und eine
       Dateiliste, die aus dem Installationsordner hinausweist, wird nicht befolgt.

  Für 3, 4, 6 und 8 wird das Setup ein zweites Mal gebaut, mit einer Mindestversion der Laufzeit, die es nicht
  gibt (/DDOTNET_MINPATCH=999), und mit kurzem Zeitablauf der Nachfrage. So lässt sich „Laufzeit fehlt“ auf
  einem Rechner prüfen, der sie hat.

.PARAMETER Force
  Läuft auch außerhalb der CI. Nur auf einem Wegwerf-Rechner benutzen.
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

if ($env:CI -ne 'true' -and -not $Force) {
    throw 'Dieses Skript verändert die WidgetTea-Installation des angemeldeten Benutzers. Außerhalb der CI nur mit -Force.'
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
[xml]$proj = Get-Content (Join-Path $root 'WidgetTea.csproj')
$version = $proj.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
$out = Join-Path $root "artifacts\$version"
$publishDir = Join-Path $out 'publish'
$setup = Join-Path $out "WidgetTea-$version-setup.exe"
$logs = Join-Path $root 'artifacts\test-logs'
$work = Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }) 'widgettea-installertest'
$settingsDir = Join-Path $env:LOCALAPPDATA 'WidgetTea'
$settingsFile = Join-Path $settingsDir 'settings.json'
$regKey = 'HKCU:\Software\WidgetTea'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$oldVersion = '1.0.0'
$askTimeout = 10   # Sekunden, die die Nachfrage der Testfassung auf eine Antwort wartet (im echten Setup 120)
$oldSetupUrl = "https://github.com/Celestial0579/WidgetTea/releases/download/v$oldVersion/WidgetTea-$oldVersion-setup.exe"

if (-not (Test-Path $setup)) { throw "Setup fehlt: $setup – erst build\release.ps1 laufen lassen." }
if ((Test-Path $regKey) -and -not $Force) { throw "WidgetTea ist auf diesem Rechner schon installiert ($regKey). Abbruch." }

Remove-Item -Recurse -Force $work, $logs -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work, $logs | Out-Null

# ---------------------------------------------------------------- Hilfen

# Fenster eines Prozesses finden, lesen und beantworten. Das Setup zeigt seine Nachfragen als gewöhnliche
# Windows-Meldungsfenster (Klasse #32770); WM_COMMAND für den passenden Knopf schließt sie.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class WtDialogs
{
    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int GetDlgCtrlID(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);

    public static long[] Find(int pid)
    {
        var found = new List<long>();
        EnumWindows((h, l) =>
        {
            uint p;
            GetWindowThreadProcessId(h, out p);
            if (p == (uint)pid && IsWindowVisible(h))
            {
                var cls = new StringBuilder(64);
                GetClassName(h, cls, cls.Capacity);
                if (cls.ToString() == "#32770") found.Add(h.ToInt64());
            }
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    public static string Text(long hWnd)
    {
        var sb = new StringBuilder();
        var title = new StringBuilder(4096);
        GetWindowText(new IntPtr(hWnd), title, title.Capacity);
        sb.Append(title).Append(" | ");
        EnumChildWindows(new IntPtr(hWnd), (h, l) =>
        {
            var c = new StringBuilder(4096);
            GetWindowText(h, c, c.Capacity);
            if (c.Length > 0) sb.Append(c).Append(" | ");
            return true;
        }, IntPtr.Zero);
        return sb.ToString();
    }

    // Drückt den Knopf mit einer der Beschriftungen. Über die Beschriftung und nicht über eine feste Kennung:
    // In einem Fenster, das nur „OK“ hat, trägt der Knopf nicht IDOK, und WM_COMMAND mit IDOK verpufft.
    public static bool PressButton(long hWnd, string[] captions)
    {
        IntPtr dialog = new IntPtr(hWnd);
        IntPtr button = IntPtr.Zero;
        EnumChildWindows(dialog, (h, l) =>
        {
            var cls = new StringBuilder(64);
            GetClassName(h, cls, cls.Capacity);
            if (cls.ToString() != "Button") return true;
            var text = new StringBuilder(256);
            GetWindowText(h, text, text.Capacity);
            string label = text.ToString().Replace("&", "");
            foreach (var caption in captions)
            {
                if (string.Equals(label, caption, StringComparison.OrdinalIgnoreCase)) { button = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        if (button == IntPtr.Zero) return false;
        PostMessage(dialog, 0x0111 /* WM_COMMAND */, new IntPtr(GetDlgCtrlID(button)), button);
        return true;
    }
}
'@

$script:stage = ''
function Step([string]$text) { $script:stage = $text; Write-Host "`n== $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "   ok  $text" -ForegroundColor Green }
function Note([string]$text) { Write-Host "   --  $text" -ForegroundColor Yellow }
function Check([bool]$condition, [string]$text) {
    if (-not $condition) { throw "[$script:stage] FEHLGESCHLAGEN: $text" }
    Ok $text
}

function Stop-App {
    Get-Process -Name 'WidgetTea' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}

# Startet ein Setup und wartet. Nachfragen werden laut $Answers beantwortet: Schlüssel = Text, der im Fenster
# stehen muss, Wert = Beschriftungen des Knopfes. Eine leere Liste lässt das Fenster unbeantwortet stehen;
# ein Skriptblock wird erst ausgeführt und liefert dann die Beschriftungen (für Prüfungen, solange das Fenster
# noch offen ist). Ein unerwartetes Fenster oder eine Zeitüberschreitung ist ein Fehler.
function Invoke-Setup {
    param(
        [string]$Exe,
        [string[]]$Arguments,
        [System.Collections.Specialized.OrderedDictionary]$Answers = [ordered]@{},
        [int]$TimeoutSec = 300,
        [string]$WorkingDirectory   # aktueller Ordner des Setups; beim Doppelklick ist es der Ordner der Setup-Datei
    )
    Write-Host "   >   $(Split-Path $Exe -Leaf) $($Arguments -join ' ')"
    $start = @{ FilePath = $Exe; ArgumentList = $Arguments; PassThru = $true }
    if ($WorkingDirectory) { $start.WorkingDirectory = $WorkingDirectory }
    $p = Start-Process @start
    $null = $p.Handle   # sonst ist ExitCode nach dem Ende leer
    $seen = [System.Collections.Generic.List[string]]::new()
    $seenAt = @{}
    $done = @{}
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $p.WaitForExit(250)) {
        foreach ($h in [WtDialogs]::Find($p.Id)) {
            $text = [WtDialogs]::Text($h)
            $id = "$h|$text"   # Fensterkennungen werden wiederverwendet, der Text gehört deshalb dazu
            if ($done.ContainsKey($id)) { continue }
            $key = $Answers.Keys | Where-Object { $text -like "*$_*" } | Select-Object -First 1
            if (-not $key) {
                Stop-Process -Id $p.Id -Force
                throw "[$script:stage] Unerwartete Nachfrage des Setups: $text"
            }
            $done[$id] = $true
            $seen.Add($key)
            $seenAt[$key] = Get-Date
            # Keine typografischen Anführungszeichen in doppelt begrenzten Zeichenketten: PowerShell liest sie als Begrenzer.
            $shown = $text.Substring(0, [Math]::Min(150, $text.Length)).Replace("`r`n", ' ')
            $answer = $Answers[$key]
            if ($answer -is [scriptblock]) { $answer = & $answer }
            $captions = [string[]]@($answer)
            if ($captions.Count -eq 0) {
                Write-Host "   ?   $shown ...  ->  bleibt unbeantwortet"
                continue
            }
            Write-Host "   ?   $shown ...  ->  Knopf $($captions[0])"
            if (-not [WtDialogs]::PressButton($h, $captions)) {
                Stop-Process -Id $p.Id -Force
                throw "[$script:stage] Kein Knopf $($captions -join ' / ') in der Nachfrage: $text"
            }
        }
        if ((Get-Date) -gt $deadline) {
            $open = ([WtDialogs]::Find($p.Id) | ForEach-Object { [WtDialogs]::Text($_) }) -join ' || '
            Stop-Process -Id $p.Id -Force
            throw "[$script:stage] Setup lief nach $TimeoutSec s noch. Offene Fenster: $open"
        }
    }
    [pscustomobject]@{ ExitCode = $p.ExitCode; Seen = $seen; SeenAt = $seenAt }
}

# Relativer Pfad, Größe und SHA-256 jeder Datei – für „hat sich nichts geändert“.
function Get-Snapshot([string]$Dir) {
    Get-ChildItem -LiteralPath $Dir -Recurse -File | Sort-Object FullName | ForEach-Object {
        '{0}|{1}|{2}' -f $_.FullName.Substring($Dir.Length), $_.Length, (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
}

function Test-SameSnapshot($a, $b) { -not (Compare-Object -ReferenceObject @($a) -DifferenceObject @($b)) }

# Startet die App und stellt fest, woher sie die .NET-Laufzeit lädt. Ein Starter, der keine Laufzeit findet,
# zeigt nur ein Meldungsfenster – der Prozess lebt dann zwar, lädt aber nie coreclr.dll.
function Get-RuntimeOfApp([string]$Exe, [string]$Label) {
    Stop-App
    $trace = Join-Path $logs "corehost-$Label.log"
    $env:COREHOST_TRACE = '1'
    $env:COREHOST_TRACEFILE = $trace
    try { $p = Start-Process -FilePath $Exe -PassThru } finally {
        Remove-Item Env:COREHOST_TRACE, Env:COREHOST_TRACEFILE -ErrorAction SilentlyContinue
    }
    $coreclr = $null
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline -and -not $p.HasExited -and -not $coreclr) {
        Start-Sleep -Milliseconds 250
        try {
            $p.Refresh()
            $coreclr = ($p.Modules | Where-Object { $_.ModuleName -eq 'coreclr.dll' } | Select-Object -First 1).FileName
        } catch { }
    }
    if (-not $coreclr -and (Test-Path $trace)) {
        # Die App kann sich auf einem Rechner ohne Desktop sofort wieder beenden. Dann zählt das Protokoll des Starters.
        $hit = Select-String -LiteralPath $trace -Pattern '[A-Za-z]:\\[^\r\n\]]*\\coreclr\.dll' -AllMatches | Select-Object -First 1
        if ($hit) { $coreclr = $hit.Matches[0].Value }
    }
    if ($p.HasExited) { Note "App hat sich selbst beendet (Exitcode $($p.ExitCode))" }
    Stop-App
    if (-not $coreclr) {
        if (Test-Path $trace) { Get-Content -LiteralPath $trace -Tail 25 | ForEach-Object { Write-Host "       $_" } }
        throw "[$script:stage] Die App hat keine .NET-Laufzeit geladen: $Exe"
    }
    Write-Host "       Laufzeit: $coreclr"
    $coreclr
}

function Test-Marker { Test-Path -LiteralPath (Join-Path $settingsDir 'autoupdate-paused') }
function Get-AutoUpdate { (Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json).autoUpdate }
function Read-Settings { [System.IO.File]::ReadAllText($settingsFile, [System.Text.Encoding]::UTF8) }
function Write-Settings([string]$text) {
    New-Item -ItemType Directory -Force $settingsDir | Out-Null
    [System.IO.File]::WriteAllText($settingsFile, $text, [System.Text.UTF8Encoding]::new($false))
}

# Text im Fenster → Beschriftung des Knopfes (englisches oder deutsches Windows).
$declineAnswers = [ordered]@{
    'Jetzt installieren?'              = @('No', 'Nein')   # Nachfrage aus DotnetRuntime.nsh
    'bleibt in der bisherigen Version' = @('OK')           # Bescheid aus UpdateDeclined
}

# ---------------------------------------------------------------- 0 Vorbereitung

Step '0 Vorbereitung'
$expected = ((Get-Content -LiteralPath "$setup.sha256" -Raw) -split '\s+')[0]
Check ((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash -eq $expected) 'Die .sha256 passt zum Setup'

$makensis = @("${env:ProgramFiles(x86)}\NSIS\makensis.exe", "$env:ProgramFiles\NSIS\makensis.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $makensis) { throw 'NSIS nicht gefunden' }
$setupNoRuntime = Join-Path $work 'WidgetTea-ohne-passende-Laufzeit-setup.exe'
& $makensis /V2 /INPUTCHARSET UTF8 "/DVERSION=$version" "/DSRCDIR=$publishDir" "/DOUTFILE=$setupNoRuntime" `
    '/DDOTNET_MINPATCH=999' "/DDOTNET_ASK_TIMEOUT=$askTimeout" (Join-Path $root 'installer\WidgetTea.nsi')
if ($LASTEXITCODE) { throw 'makensis (Testfassung) fehlgeschlagen' }
Ok 'Testfassung des Setups gebaut (verlangt eine Laufzeit, die es nicht gibt)'

# ---------------------------------------------------------------- 1 Neuinstallation

Step '1 Neuinstallation, still'
$fresh = Join-Path $work 'frisch'
$r = Invoke-Setup $setup @('/S', "/D=$fresh")
Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
foreach ($f in 'WidgetTea.exe', 'WidgetTea.dll', 'WidgetTea.runtimeconfig.json', 'LICENSE.txt', 'uninstall.exe') {
    Check (Test-Path (Join-Path $fresh $f)) "$f ist da"
}
Check (-not (Test-Path (Join-Path $fresh 'coreclr.dll'))) 'Das Setup bringt keine .NET-Laufzeit mehr mit'
Check ((Get-ItemProperty $regKey).InstallDir -eq $fresh) 'Installationsort ist vermerkt'
Check ((Get-Item (Join-Path $fresh 'WidgetTea.exe')).VersionInfo.ProductVersion -like "$version*") "Installiert ist Version $version"
$runtime = Get-RuntimeOfApp (Join-Path $fresh 'WidgetTea.exe') 'neuinstallation'
Check ($runtime -match '\\shared\\Microsoft\.NETCore\.App\\10\.0\.\d+\\coreclr\.dll$') 'Die App startet mit der installierten Laufzeit'

Start-Process -FilePath (Join-Path $fresh 'uninstall.exe') -ArgumentList '/S' -Wait
$deadline = (Get-Date).AddSeconds(60)
while ((Test-Path $fresh) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
Check (-not (Test-Path $fresh)) 'Deinstallation entfernt den Ordner'
Check (-not (Test-Path $regKey)) 'Deinstallation entfernt die Registry-Einträge'
Check (-not (Get-ItemProperty -Path $runKey -Name 'WidgetTea' -ErrorAction SilentlyContinue)) 'Deinstallation entfernt den Autostart'

# ---------------------------------------------------------------- 2 Ausgangslage 1.0.0

Step "2 Ausgangslage: veröffentlichtes Setup $oldVersion"
$oldSetup = Join-Path $work "WidgetTea-$oldVersion-setup.exe"
Invoke-WebRequest -Uri $oldSetupUrl -OutFile $oldSetup
Invoke-WebRequest -Uri "$oldSetupUrl.sha256" -OutFile "$oldSetup.sha256"
$expected = ((Get-Content -LiteralPath "$oldSetup.sha256" -Raw) -split '\s+')[0]
Check ((Get-FileHash -LiteralPath $oldSetup -Algorithm SHA256).Hash -eq $expected) "Setup $oldVersion geladen, Prüfsumme stimmt"

$dir = Join-Path $work 'update'
$r = Invoke-Setup $oldSetup @('/S', "/D=$dir")
Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
Check (Test-Path (Join-Path $dir 'coreclr.dll')) "$oldVersion bringt die .NET-Laufzeit selbst mit"
Write-Host "       $((Get-ChildItem $dir -Recurse -File).Count) Dateien, $((Get-ChildItem $dir -Directory).Count) Unterordner"

# Beim Update entfernt das Setup genau die Dateien von $oldVersion (installer\Bundled-1.0.0.nsh). Die Liste dort muss
# deshalb mit dem übereinstimmen, was das veröffentlichte Setup wirklich installiert. Die tatsächliche Liste liegt
# bei den Protokollen des Laufs, Ordner mit „\" am Ende.
$oldFiles = @(Get-ChildItem -LiteralPath $dir -Recurse -File | ForEach-Object { $_.FullName.Substring($dir.Length + 1) })
$oldDirs = @(Get-ChildItem -LiteralPath $dir -Recurse -Directory | ForEach-Object { $_.FullName.Substring($dir.Length + 1) })
Set-Content -LiteralPath (Join-Path $logs "dateien-$oldVersion.txt") -Encoding ascii -Value (@($oldFiles | Sort-Object) + @($oldDirs | Sort-Object | ForEach-Object { "$_\" }))
$bundled = Get-Content -LiteralPath (Join-Path $root 'installer\Bundled-1.0.0.nsh')
$listedFiles = @($bundled | ForEach-Object { if ($_ -match '^Delete "\$INSTDIR\\(.+)"$') { $Matches[1] } })
$listedDirs = @($bundled | ForEach-Object { if ($_ -match '^RMDir "\$INSTDIR\\(.+)"$') { $Matches[1] } })
$diff = @(Compare-Object -ReferenceObject $oldFiles -DifferenceObject $listedFiles | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" })
Check ($diff.Count -eq 0) "Die hinterlegte Liste nennt genau die $($oldFiles.Count) Dateien von $oldVersion (Abweichung: $(($diff | Select-Object -First 5) -join ', '))"
$diff = @(Compare-Object -ReferenceObject $oldDirs -DifferenceObject $listedDirs | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" })
Check ($diff.Count -eq 0) "und genau die $($oldDirs.Count) Unterordner (Abweichung: $(($diff | Select-Object -First 5) -join ', '))"

# Fremde Dateien: Wer in einen Ordner mit eigenen Dingen installiert hat, darf sie beim Update nicht verlieren.
# Auch keine eigenen DLLs, weder im Hauptordner noch in einem Ordner, der so heißt wie ein Sprachordner der Laufzeit.
Set-Content -LiteralPath (Join-Path $dir 'meine-notizen.txt') -Value 'gehört nicht zu WidgetTea' -Encoding utf8
Set-Content -LiteralPath (Join-Path $dir 'eigene-bibliothek.dll') -Value 'auch eine DLL kann fremd sein' -Encoding utf8
Set-Content -LiteralPath (Join-Path $dir 'de\fremd.resources.dll') -Value 'und eine im Sprachordner' -Encoding utf8
New-Item -ItemType Directory -Force (Join-Path $dir 'eigener-ordner') | Out-Null
Set-Content -LiteralPath (Join-Path $dir 'eigener-ordner\daten.txt') -Value 'auch nicht' -Encoding utf8

# Einstellungen, wie die App sie schreibt: eingerückt, CRLF, UTF-8 ohne BOM. Der Umlaut steht vor der Stelle,
# die das Setup ändert – käme die Datei dabei durch eine Zeichensatz-Umwandlung, fiele es hier auf.
$settingsOriginal = @(
    '{'
    '  "baseUrl": "https://gitea.example.com",'
    '  "username": "Jörg Müller",'
    '  "refreshMinutes": 15,'
    '  "timeoutSeconds": 10,'
    '  "ignoreCertificateErrors": false,'
    '  "autoUpdate": true,'
    '  "left": 1200.5,'
    '  "top": null,'
    '  "locked": false'
    '}'
) -join "`r`n"
Write-Settings $settingsOriginal
Ok 'Fremde Dateien und Einstellungen angelegt'

# ---------------------------------------------------------------- 3 Still, Laufzeit fehlt

Step '3 /S ohne passende Laufzeit'
$before = Get-Snapshot $dir
$r = Invoke-Setup $setupNoRuntime @('/S') -TimeoutSec 120
Check ($r.ExitCode -eq 3) "Exitcode 3 (war $($r.ExitCode))"
Check ($r.Seen.Count -eq 0) 'Keine Nachfrage'
Check (Test-SameSnapshot $before (Get-Snapshot $dir)) 'Die vorhandene Installation ist Byte für Byte unverändert'
Check ((Read-Settings) -ceq $settingsOriginal) 'Die Einstellungen sind unverändert'

# ---------------------------------------------------------------- 4 Selbst-Update abgelehnt

Step "4 /S /RESTART ohne passende Laufzeit, Nachfrage abgelehnt (installiert: $oldVersion)"
$r = Invoke-Setup $setupNoRuntime @('/S', '/RESTART') -Answers $declineAnswers -TimeoutSec 180
$settingsNow = Read-Settings   # sofort lesen, bevor eine wieder gestartete App etwas schreiben könnte
$relaunched = $false
$deadline = (Get-Date).AddSeconds(20)
while (-not $relaunched -and (Get-Date) -lt $deadline) {
    $relaunched = [bool](Get-Process -Name 'WidgetTea' -ErrorAction SilentlyContinue)
    if (-not $relaunched) { Start-Sleep -Milliseconds 500 }
}
Stop-App
Check ($r.ExitCode -eq 3) "Exitcode 3 (war $($r.ExitCode))"
Check ($r.Seen -contains 'Jetzt installieren?') 'Das Setup hat trotz /S nachgefragt'
Check ($r.Seen -contains 'bleibt in der bisherigen Version') 'Das Setup hat gesagt, wie es weitergeht'
Check (Test-SameSnapshot $before (Get-Snapshot $dir)) 'Die vorhandene Installation ist Byte für Byte unverändert'
Check ($settingsNow -ceq $settingsOriginal.Replace('"autoUpdate": true', '"autoUpdate":false')) 'In den Einstellungen ist genau diese eine Stelle geändert'
Check ((Get-AutoUpdate) -eq $false) 'Automatische Updates sind aus, die Datei ist gültiges JSON'
Check (Test-Marker) 'Der Merker für die Rücknahme liegt neben den Einstellungen'
if ($relaunched) { Ok 'Die alte Version wurde wieder gestartet' } else { Note 'Wiederstart der alten Version hier nicht beobachtet (explorer.exe startet in dieser Sitzung nichts?)' }

# ---------------------------------------------------------------- 5 Update 1.0.0 → neu

Step "5 Update $oldVersion → $version wie vom Updater (/S /RESTART)"
$foreignBefore = Get-Snapshot (Join-Path $dir 'eigener-ordner')
$r = Invoke-Setup $setup @('/S', '/RESTART')
$relaunched = $false
$deadline = (Get-Date).AddSeconds(20)
while (-not $relaunched -and (Get-Date) -lt $deadline) {
    $relaunched = [bool](Get-Process -Name 'WidgetTea' -ErrorAction SilentlyContinue)
    if (-not $relaunched) { Start-Sleep -Milliseconds 500 }
}
Stop-App
Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
Check ($r.Seen.Count -eq 0) 'Keine Nachfrage'
foreach ($f in 'coreclr.dll', 'hostfxr.dll', 'hostpolicy.dll', 'clrjit.dll', 'createdump.exe', 'System.Private.CoreLib.dll', 'PresentationFramework.dll') {
    Check (-not (Test-Path (Join-Path $dir $f))) "$f ist weg"
}
# Nichts darf liegen bleiben: Im Hauptordner steht genau das, was das neue Setup mitbringt, plus die fremde Datei.
$expectedFiles = @(@(Get-ChildItem -LiteralPath $publishDir -File | ForEach-Object Name) + 'LICENSE.txt', 'uninstall.exe', 'WidgetTea-installed-files.txt', 'meine-notizen.txt', 'eigene-bibliothek.dll' | Sort-Object)
$actualFiles = @(Get-ChildItem -LiteralPath $dir -File | ForEach-Object Name | Sort-Object)
Write-Host "       Hauptordner: $($actualFiles -join ', ')"
$unexpected = @(Compare-Object -ReferenceObject $expectedFiles -DifferenceObject $actualFiles | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" })
Check ($unexpected.Count -eq 0) "Im Hauptordner liegt genau das neue Programm, seine Dateiliste und die fremden Dateien (Abweichung: $($unexpected -join ', '))"
$subdirs = @(Get-ChildItem -LiteralPath $dir -Directory | ForEach-Object Name | Sort-Object)
Check (($subdirs -join '|') -eq 'de|eigener-ordner') "Die Sprachordner der Laufzeit sind weg, bis auf den mit der fremden Datei (übrig: $($subdirs -join ', '))"
$inDe = @(Get-ChildItem -LiteralPath (Join-Path $dir 'de') -File | ForEach-Object Name)
Check (($inDe -join '|') -eq 'fremd.resources.dll') "Dort liegt nur noch die fremde Datei (übrig: $($inDe -join ', '))"
Check (Test-Path (Join-Path $dir 'meine-notizen.txt')) 'Die fremde Datei im Hauptordner ist noch da'
Check (Test-Path (Join-Path $dir 'eigene-bibliothek.dll')) 'Die fremde DLL im Hauptordner ist noch da'
Check (Test-SameSnapshot $foreignBefore (Get-Snapshot (Join-Path $dir 'eigener-ordner'))) 'Der fremde Unterordner ist unverändert'
Check ((Get-Item (Join-Path $dir 'WidgetTea.exe')).VersionInfo.ProductVersion -like "$version*") "Installiert ist Version $version"
Check ((Read-Settings) -ceq $settingsOriginal) 'Die Einstellungen sind wieder genau wie vorher, automatische Updates an'
Check (-not (Test-Marker)) 'Der Merker ist gelöscht'
if ($relaunched) { Ok 'Das Setup hat die neue Version gestartet' } else { Note 'Start durch das Setup hier nicht beobachtet (explorer.exe startet in dieser Sitzung nichts?)' }
$runtime = Get-RuntimeOfApp (Join-Path $dir 'WidgetTea.exe') 'nach-update'
Check ($runtime -match '\\shared\\Microsoft\.NETCore\.App\\10\.0\.\d+\\coreclr\.dll$') 'Die App startet nach dem Update mit der installierten Laufzeit'

# ---------------------------------------------------------------- 6 Ablehnen auf der neuen Fassung

Step "6 /S /RESTART ohne passende Laufzeit, abgelehnt (installiert: $version)"
$before = Get-Snapshot $dir
$r = Invoke-Setup $setupNoRuntime @('/S', '/RESTART') -Answers $declineAnswers -TimeoutSec 180
$settingsNow = Read-Settings
Stop-App
Check ($r.ExitCode -eq 3) "Exitcode 3 (war $($r.ExitCode))"
Check (Test-SameSnapshot $before (Get-Snapshot $dir)) 'Die vorhandene Installation ist Byte für Byte unverändert'
Check ($settingsNow -ceq $settingsOriginal.Replace('"autoUpdate": true', '"autoUpdate":false')) 'Automatische Updates sind aus'
Check (Test-Marker) 'Der Merker ist gesetzt'
# Die App speichert ihre Einstellungen neu (etwa nach dem Verschieben des Fensters) und schreibt dabei „: false“.
Write-Settings $settingsOriginal.Replace('"autoUpdate": true', '"autoUpdate": false')

# ---------------------------------------------------------------- 7 Update neu → neu

Step "7 Update $version → $version (/S /RESTART)"
$r = Invoke-Setup $setup @('/S', '/RESTART')
Start-Sleep -Seconds 3
Stop-App
Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
Check (Test-Path (Join-Path $dir 'meine-notizen.txt')) 'Die fremde Datei im Hauptordner ist noch da'
Check (Test-SameSnapshot $foreignBefore (Get-Snapshot (Join-Path $dir 'eigener-ordner'))) 'Der fremde Unterordner ist unverändert'
Check ((Read-Settings) -ceq $settingsOriginal.Replace('"autoUpdate": true', '"autoUpdate": true ')) 'Automatische Updates sind wieder an, sonst ist nichts geändert'
Check ((Get-AutoUpdate) -eq $true) 'Die Datei ist gültiges JSON'
Check (-not (Test-Marker)) 'Der Merker ist gelöscht'

# ---------------------------------------------------------------- 8 Niemand antwortet

Step "8 /S /RESTART ohne passende Laufzeit, niemand antwortet (Zeitablauf $askTimeout s)"
Write-Settings $settingsOriginal
$before = Get-Snapshot $dir
$script:runningWhileHintOpen = $false
$timeoutAnswers = [ordered]@{
    'Auf die Nachfrage kam keine Antwort' = {
        # Der Hinweis steht noch auf dem Schirm. Das Widget muss trotzdem schon wieder laufen – sonst bliebe es
        # geschlossen, bis jemand zurückkommt.
        $limit = (Get-Date).AddSeconds(30)
        while (-not (Get-Process -Name 'WidgetTea' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $limit) { Start-Sleep -Milliseconds 500 }
        $script:runningWhileHintOpen = [bool](Get-Process -Name 'WidgetTea' -ErrorAction SilentlyContinue)
        @('OK')
    }
    'Jetzt installieren?'                 = @()   # niemand antwortet
}
$r = Invoke-Setup $setupNoRuntime @('/S', '/RESTART') -Answers $timeoutAnswers -TimeoutSec 180
$settingsNow = Read-Settings
Stop-App
Check ($r.ExitCode -eq 3) "Exitcode 3 (war $($r.ExitCode))"
Check ($r.Seen -contains 'Jetzt installieren?') 'Das Setup hat nachgefragt'
Check ($r.Seen -contains 'Auf die Nachfrage kam keine Antwort') 'Nach dem Zeitablauf sagt das Setup, was geschehen ist'
$waited = ($r.SeenAt['Auf die Nachfrage kam keine Antwort'] - $r.SeenAt['Jetzt installieren?']).TotalSeconds
Check ($waited -ge ($askTimeout - 2) -and $waited -le ($askTimeout + 20)) "Die Nachfrage blieb etwa $askTimeout s stehen (gemessen: $([int]$waited) s)"
Check $script:runningWhileHintOpen 'Das Widget lief schon wieder, während der Hinweis noch offen war'
Check (Test-SameSnapshot $before (Get-Snapshot $dir)) 'Die vorhandene Installation ist Byte für Byte unverändert'
Check ($settingsNow -ceq $settingsOriginal.Replace('"autoUpdate": true', '"autoUpdate":false')) 'Automatische Updates sind ausgesetzt wie bei Nein'
Check (Test-Marker) 'Der Merker ist gesetzt'

# ---------------------------------------------------------------- 9 Deinstallation, fremde Dateien bleiben

Step '9 Deinstallation mit fremden Dateien im Ordner'
Start-Process -FilePath (Join-Path $dir 'uninstall.exe') -ArgumentList '/S' -Wait
$deadline = (Get-Date).AddSeconds(60)
while ((Test-Path (Join-Path $dir 'uninstall.exe')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
$left = @(Get-ChildItem -LiteralPath $dir -Recurse -File | ForEach-Object { $_.FullName.Substring($dir.Length + 1) } | Sort-Object)
Write-Host "       Übrig: $($left -join ', ')"
$foreign = @('de\fremd.resources.dll', 'eigene-bibliothek.dll', 'eigener-ordner\daten.txt', 'meine-notizen.txt')
Check (-not (Compare-Object -ReferenceObject $foreign -DifferenceObject $left)) 'Im Ordner liegen nur noch die fremden Dateien'
Check (Test-SameSnapshot $foreignBefore (Get-Snapshot (Join-Path $dir 'eigener-ordner'))) 'Der fremde Unterordner ist unverändert'
Check (-not (Test-Path $regKey)) 'Die Registry-Einträge sind weg'
Check (-not (Get-ItemProperty -Path $runKey -Name 'WidgetTea' -ErrorAction SilentlyContinue)) 'Der Autostart ist weg'
Check (-not (Test-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\WidgetTea.lnk'))) 'Die Verknüpfung im Startmenü ist weg'
Check (Test-Path -LiteralPath $settingsFile) 'Die Einstellungen des Nutzers bleiben liegen (Benutzerdaten nicht abgewählt)'

# ---------------------------------------------------------------- 10 Fremde Programme neben dem Setup

Step '10 Fremde Programme neben dem Setup werden nicht ausgeführt'
# Das Setup ruft Hilfsprogramme von Windows auf. Nennt es sie nur beim Namen, sucht Windows zuerst im Ordner des
# Setups und im aktuellen Ordner, und beim Doppelklick ist das der Ordner, in dem die Setup-Datei liegt. Die Köder
# hier sind harmlose Programme mit den Namen dieser Hilfsprogramme: Sie schreiben nur auf, dass sie gestartet wurden.
$csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw 'csc.exe von .NET Framework 4 fehlt, die Köder lassen sich nicht bauen' }
$baitLog = Join-Path $work 'koeder-gelaufen.txt'
$baitExe = Join-Path $work 'koeder.exe'
$sleeperExe = Join-Path $work 'schlaefer.exe'
Set-Content -LiteralPath (Join-Path $work 'koeder.cs') -Encoding ascii -Value @'
using System;
using System.Diagnostics;
using System.IO;
public static class Koeder
{
    public static int Main(string[] args)
    {
        try
        {
            File.AppendAllText(Environment.GetEnvironmentVariable("WIDGETTEA_KOEDER"),
                Process.GetCurrentProcess().MainModule.FileName + " " + string.Join(" ", args) + Environment.NewLine);
        }
        catch { }
        return 1;
    }
}
'@
Set-Content -LiteralPath (Join-Path $work 'schlaefer.cs') -Encoding ascii -Value @'
public static class Schlaefer
{
    public static void Main() { System.Threading.Thread.Sleep(600000); }
}
'@
& $csc /nologo "/out:$baitExe" (Join-Path $work 'koeder.cs') | Out-Null
if ($LASTEXITCODE) { throw 'Der Köder ließ sich nicht übersetzen' }
& $csc /nologo "/out:$sleeperExe" (Join-Path $work 'schlaefer.cs') | Out-Null
if ($LASTEXITCODE) { throw 'Der Schläfer ließ sich nicht übersetzen' }

# Ordner mit einer Kopie des Setups und den Ködern daneben; liefert den Pfad der Kopie.
function New-BaitFolder([string]$Name, [string]$SetupFile) {
    $folder = Join-Path $work $Name
    New-Item -ItemType Directory -Force $folder | Out-Null
    Copy-Item -LiteralPath $SetupFile -Destination $folder
    foreach ($n in 'cmd.exe', 'tasklist.exe', 'find.exe', 'taskkill.exe', 'where.exe', 'winget.exe') {
        Copy-Item -LiteralPath $baitExe -Destination (Join-Path $folder $n)
    }
    Join-Path $folder (Split-Path $SetupFile -Leaf)
}

function Show-BaitLog {
    if (Test-Path -LiteralPath $baitLog) { Get-Content -LiteralPath $baitLog | ForEach-Object { Write-Host "       Köder: $_" } }
}

function Wait-Gone([string]$Path) {
    $deadline = (Get-Date).AddSeconds(60)
    while ((Test-Path -LiteralPath $Path) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
}

$env:WIDGETTEA_KOEDER = $baitLog
$sleeper = $null
try {
    Start-Process -FilePath $baitExe -ArgumentList 'Selbsttest' -Wait -WindowStyle Hidden
    Check ((Test-Path -LiteralPath $baitLog) -and (Get-Content -LiteralPath $baitLog -Raw) -like '*Selbsttest*') 'Der Köder meldet sich, wenn er gestartet wird'
    Remove-Item -LiteralPath $baitLog

    # Gegenprobe: Das veröffentlichte Setup ruft cmd.exe und taskkill noch ohne Pfad auf. Schlägt der Köder dort
    # nicht an, taugt diese Stufe nicht als Prüfung.
    $oldBait = New-BaitFolder 'koeder-alt' $oldSetup
    $oldTarget = Join-Path $work 'koeder-alt-ziel'
    $r = Invoke-Setup $oldBait @('/S', "/D=$oldTarget") -WorkingDirectory (Split-Path $oldBait)
    Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
    Show-BaitLog
    Check (Test-Path -LiteralPath $baitLog) "Gegenprobe: Das veröffentlichte Setup $oldVersion startet einen Köder"
    Remove-Item -LiteralPath $baitLog
    Start-Process -FilePath (Join-Path $oldTarget 'uninstall.exe') -ArgumentList '/S' -Wait
    Wait-Gone $oldTarget

    # Das gebaute Setup, frische Installation.
    $newBait = New-BaitFolder 'koeder-neu' $setup
    $target = Join-Path $work 'koeder-neu-ziel'
    $r = Invoke-Setup $newBait @('/S', "/D=$target") -WorkingDirectory (Split-Path $newBait)
    Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
    Check (Test-Path (Join-Path $target 'WidgetTea.exe')) 'Die Installation ist vollständig'
    Show-BaitLog
    Check (-not (Test-Path -LiteralPath $baitLog)) 'Das Setup hat keinen Köder gestartet'

    # Dasselbe, während im Zielordner ein Programm namens WidgetTea.exe läuft. Jetzt muss das Setup es beenden,
    # ruft also auch taskkill auf.
    Copy-Item -LiteralPath $sleeperExe -Destination (Join-Path $target 'WidgetTea.exe') -Force
    $sleeper = Start-Process -FilePath (Join-Path $target 'WidgetTea.exe') -PassThru -WindowStyle Hidden
    $null = $sleeper.Handle
    Start-Sleep -Seconds 1
    Check (-not $sleeper.HasExited) 'Im Zielordner läuft ein Programm namens WidgetTea.exe'
    $r = Invoke-Setup $newBait @('/S', "/D=$target") -WorkingDirectory (Split-Path $newBait)
    Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
    Check ($sleeper.WaitForExit(5000)) 'Das Setup hat das laufende Programm beendet'
    Check ((Get-Item (Join-Path $target 'WidgetTea.exe')).VersionInfo.ProductVersion -like "$version*") 'Im Zielordner liegt wieder das echte Programm'
    Show-BaitLog
    Check (-not (Test-Path -LiteralPath $baitLog)) 'Auch dabei hat das Setup keinen Köder gestartet'

    Start-Process -FilePath (Join-Path $target 'uninstall.exe') -ArgumentList '/S' -Wait
    Wait-Gone $target
    Check (-not (Test-Path $target)) 'Die Deinstallation entfernt den Ordner'
    Check (-not (Test-Path $regKey)) 'Die Registry-Einträge sind weg'
}
finally {
    Remove-Item Env:WIDGETTEA_KOEDER -ErrorAction SilentlyContinue
    if ($sleeper -and -not $sleeper.HasExited) { Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue }
}

# Und im Quelltext: Jeder Aufruf eines Programms nennt es mit vollem Pfad.
$calls = @(Get-ChildItem -LiteralPath (Join-Path $root 'installer') -Recurse -File -Include '*.nsi', '*.nsh' |
    Select-String -Pattern '^\s*(nsExec::\w+|Exec|ExecWait)\s+''(.+)''\s*$')
Check ($calls.Count -ge 4) "Aufrufe von Programmen im Quelltext des Setups gefunden: $($calls.Count)"
$bare = @($calls | Where-Object { $_.Matches[0].Groups[2].Value -notmatch '^"\$(SYSDIR|WINDIR|LOCALAPPDATA)\\' })
foreach ($b in $bare) { Write-Host "       $($b.Filename):$($b.LineNumber): $($b.Line.Trim())" }
Check ($bare.Count -eq 0) 'Jeder davon nennt das Programm mit vollem Pfad'

# winget ruft das Setup über seinen festen Ort im Benutzerprofil auf. Ob nsExec es von dort starten kann, zeigt ein
# Probe-Setup mit genau diesem Aufruf. Gibt es winget auf diesem Rechner nicht, muss nsExec das als "error" melden
# und trotzdem zwei Werte auf den Stapel legen, denn das Setup holt zwei herunter.
$probeNsi = Join-Path $work 'winget-probe.nsi'
$probeExe = Join-Path $work 'winget-probe.exe'
$probeOut = Join-Path $work 'winget-probe.txt'
Set-Content -LiteralPath $probeNsi -Encoding ascii -Value @'
Unicode true
RequestExecutionLevel user
SilentInstall silent
OutFile "${OUTFILE}"
Section
  Push "unten"
  nsExec::ExecToStack '"$LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" --version'
  Pop $1
  Pop $0
  Pop $3
  FileOpen $2 "${RESULT}" w
  FileWrite $2 "$1|$0|$3"
  FileClose $2
SectionEnd
'@
& $makensis /V2 "/DOUTFILE=$probeExe" "/DRESULT=$probeOut" $probeNsi | Out-Null
if ($LASTEXITCODE) { throw 'makensis (winget-Probe) fehlgeschlagen' }
Start-Process -FilePath $probeExe -Wait
$probe = ((Get-Content -LiteralPath $probeOut -Raw) -replace '\s+', ' ').Trim()
if (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe')) {
    Check ($probe -match '^0\|v?\d+\.\d+.*\|unten$') "winget ist vorhanden und antwortet über den festen Pfad: $probe"
} else {
    Check ($probe -match '^error\|\|unten$') "winget fehlt auf diesem Rechner, und nsExec meldet das als error: $probe"
}

# ---------------------------------------------------------------- 11 Laufende App gezielt erkennen

Step '11 Das Setup erkennt die laufende App an ihr selbst, nicht am Programmnamen'
# Zwei Stellvertreter: Der Schläfer aus Stufe 10 heißt nur WidgetTea.exe. Der Halter hält zusätzlich den Mutex,
# mit dem die App eine zweite Instanz verhindert, und gilt dem Setup deshalb als laufendes WidgetTea.
$holderExe = Join-Path $work 'halter.exe'
Set-Content -LiteralPath (Join-Path $work 'halter.cs') -Encoding ascii -Value @'
public static class Halter
{
    public static void Main()
    {
        bool created;
        using (new System.Threading.Mutex(true, @"Local\WidgetTea.SingleInstance", out created))
        {
            System.Threading.Thread.Sleep(600000);
        }
    }
}
'@
& $csc /nologo "/out:$holderExe" (Join-Path $work 'halter.cs') | Out-Null
if ($LASTEXITCODE) { throw 'Der Halter ließ sich nicht übersetzen' }

# Testfassung des Setups, die nichts beendet: An ihr zeigt sich, dass das Setup aufgibt.
$setupNoKill = Join-Path $work 'WidgetTea-beendet-nichts-setup.exe'
& $makensis /V2 /INPUTCHARSET UTF8 "/DVERSION=$version" "/DSRCDIR=$publishDir" "/DOUTFILE=$setupNoKill" `
    '/DCLOSE_APP_NO_KILL=1' (Join-Path $root 'installer\WidgetTea.nsi')
if ($LASTEXITCODE) { throw 'makensis (Testfassung ohne Beenden) fehlgeschlagen' }

# Startet einen Stellvertreter unter dem Namen WidgetTea.exe aus dem angegebenen Ordner.
function Start-StandIn([string]$Program, [string]$Folder) {
    New-Item -ItemType Directory -Force $Folder | Out-Null
    Copy-Item -LiteralPath $Program -Destination (Join-Path $Folder 'WidgetTea.exe') -Force
    $p = Start-Process -FilePath (Join-Path $Folder 'WidgetTea.exe') -PassThru -WindowStyle Hidden
    $null = $p.Handle
    Start-Sleep -Seconds 1
    if ($p.HasExited) { throw "[$script:stage] Der Stellvertreter in $Folder hat sich sofort beendet" }
    $p
}

$target = Join-Path $work 'gezielt'
$standIns = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
try {
    # a) Ein fremdes Programm gleichen Namens in einem anderen Ordner geht das Setup nichts an.
    $stranger = Start-StandIn $sleeperExe (Join-Path $work 'fremdes-programm')
    $standIns.Add($stranger)
    $r = Invoke-Setup $setup @('/S', "/D=$target") -TimeoutSec 120
    Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
    Check ((Get-Item (Join-Path $target 'WidgetTea.exe')).VersionInfo.ProductVersion -like "$version*") 'Die Installation ist vollständig'
    Check (-not $stranger.HasExited) 'Das fremde Programm gleichen Namens läuft weiter'
    Stop-Process -Id $stranger.Id -Force

    # b) Ein WidgetTea aus einem anderen Ordner (zweite Installation) hält den Mutex der App und wird beendet.
    $second = Start-StandIn $holderExe (Join-Path $work 'zweite-installation')
    $standIns.Add($second)
    $r = Invoke-Setup $setup @('/S', "/D=$target") -TimeoutSec 120
    Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
    Check ($second.WaitForExit(5000)) 'Das laufende WidgetTea aus dem anderen Ordner wurde beendet'

    # c) Lässt sich die App nicht beenden, gibt das Setup auf, statt endlos zu wiederholen.
    $blocker = Start-StandIn $sleeperExe $target
    $standIns.Add($blocker)
    $before = Get-Snapshot $target
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Setup $setupNoKill @('/S', "/D=$target") -TimeoutSec 120
    $watch.Stop()
    Check ($r.ExitCode -eq 2) "Exitcode 2, abgebrochen (war $($r.ExitCode))"
    Write-Host "       aufgegeben nach $([int]$watch.Elapsed.TotalSeconds) s"
    Check (-not $blocker.HasExited) 'Das Programm im Zielordner läuft noch'
    Check (Test-SameSnapshot $before (Get-Snapshot $target)) 'Am Installationsordner hat sich nichts geändert'
    Stop-Process -Id $blocker.Id -Force
    $blocker.WaitForExit(5000) | Out-Null

    # d) Die Deinstallation beendet die laufende App und räumt auf.
    $r = Invoke-Setup $setup @('/S', "/D=$target") -TimeoutSec 120
    Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
    $running = Start-StandIn $holderExe $target
    $standIns.Add($running)
    Start-Process -FilePath (Join-Path $target 'uninstall.exe') -ArgumentList '/S' -Wait
    Wait-Gone $target
    Check ($running.WaitForExit(5000)) 'Die Deinstallation hat die laufende App beendet'
    Check (-not (Test-Path $target)) 'Die Deinstallation entfernt den Ordner'
    Check (-not (Test-Path $regKey)) 'Die Registry-Einträge sind weg'
}
finally {
    foreach ($p in $standIns) {
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------- 12 Wegfallende Dateien

Step '12 Dateien, die in der neuen Fassung wegfallen, verschwinden beim Update'
# Als „frühere Fassung" dient dasselbe Programm mit drei Dateien mehr. Das gebaute Setup kennt sie nicht; es
# erfährt von ihnen nur aus der Dateiliste, die das frühere Setup im Installationsordner hinterlassen hat.
$earlierPayload = Join-Path $work 'programm-frueher'
Copy-Item -LiteralPath $publishDir -Destination $earlierPayload -Recurse
Set-Content -LiteralPath (Join-Path $earlierPayload 'alte-bibliothek.dll') -Value 'fällt später weg' -Encoding utf8
New-Item -ItemType Directory -Force (Join-Path $earlierPayload 'alt'), (Join-Path $earlierPayload 'alt-leer') | Out-Null
Set-Content -LiteralPath (Join-Path $earlierPayload 'alt\daten.bin') -Value 'auch' -Encoding utf8
Set-Content -LiteralPath (Join-Path $earlierPayload 'alt-leer\rest.bin') -Value 'auch' -Encoding utf8
$setupEarlier = Join-Path $work 'WidgetTea-frueher-setup.exe'
& $makensis /V2 /INPUTCHARSET UTF8 "/DVERSION=$version" "/DSRCDIR=$earlierPayload" "/DOUTFILE=$setupEarlier" (Join-Path $root 'installer\WidgetTea.nsi')
if ($LASTEXITCODE) { throw 'makensis (frühere Fassung) fehlgeschlagen' }

$target = Join-Path $work 'wegfall'
$manifest = Join-Path $target 'WidgetTea-installed-files.txt'
$r = Invoke-Setup $setupEarlier @('/S', "/D=$target")
Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
$listed = @(Get-Content -LiteralPath $manifest)
Write-Host "       Dateiliste der früheren Fassung: $($listed -join ', ')"
Check ($listed[0] -ceq 'WidgetTea installed files 1') 'Die Liste beginnt mit der Kennzeile'
foreach ($entry in 'WidgetTea.exe', 'alte-bibliothek.dll', 'alt\daten.bin', 'alt-leer\rest.bin', 'LICENSE.txt', 'alt\', 'alt-leer\') {
    Check ($listed -contains $entry) "Die Liste nennt $entry"
}
# Fremdes dazu: eine DLL im Hauptordner und eine Datei in einem Ordner, den die frühere Fassung angelegt hat.
Set-Content -LiteralPath (Join-Path $target 'meine.dll') -Value 'fremd' -Encoding utf8
Set-Content -LiteralPath (Join-Path $target 'alt\meins.txt') -Value 'fremd' -Encoding utf8

$r = Invoke-Setup $setup @('/S', "/D=$target")
Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
Check (-not (Test-Path (Join-Path $target 'alte-bibliothek.dll'))) 'Die weggefallene Datei im Hauptordner ist weg'
Check (-not (Test-Path (Join-Path $target 'alt\daten.bin'))) 'Die weggefallene Datei im Unterordner ist weg'
Check (-not (Test-Path (Join-Path $target 'alt-leer'))) 'Der Ordner, der danach leer war, ist weg'
Check (Test-Path (Join-Path $target 'alt\meins.txt')) 'Die fremde Datei im Unterordner ist noch da, der Ordner also auch'
Check (Test-Path (Join-Path $target 'meine.dll')) 'Die fremde DLL im Hauptordner ist noch da'
Check ((Get-Item (Join-Path $target 'WidgetTea.exe')).VersionInfo.ProductVersion -like "$version*") 'Das Programm ist vollständig installiert'
$listed = @(Get-Content -LiteralPath $manifest)
Check (-not ($listed -contains 'alte-bibliothek.dll')) 'Die neue Dateiliste nennt die weggefallene Datei nicht mehr'

# Eine Liste, die aus dem Ordner hinausweist oder mehr als eine Datei meint, wird an diesen Stellen nicht befolgt.
$outside = Join-Path $work 'draussen.txt'
Set-Content -LiteralPath $outside -Value 'liegt außerhalb' -Encoding utf8
Add-Content -LiteralPath $manifest -Encoding ascii -Value '..\draussen.txt', $outside, '*.dll', '\draussen.txt', 'alt\..\..\draussen.txt'
$r = Invoke-Setup $setup @('/S', "/D=$target")
Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
Check (Test-Path -LiteralPath $outside) 'Die Datei außerhalb des Installationsordners ist noch da'
Check (Test-Path (Join-Path $target 'meine.dll')) 'Der Platzhalter *.dll hat die fremde DLL nicht getroffen'

# Eine Datei dieses Namens ohne die Kennzeile stammt nicht vom Setup, etwa von einem anderen Programm im selben
# Ordner. Sie wird gar nicht befolgt, auch nicht für schlichte Pfade.
Set-Content -LiteralPath $manifest -Encoding ascii -Value 'meine.dll', 'alt\meins.txt'
$r = Invoke-Setup $setup @('/S', "/D=$target")
Check ($r.ExitCode -eq 0) "Exitcode 0 (war $($r.ExitCode))"
Check ((Test-Path (Join-Path $target 'meine.dll')) -and (Test-Path (Join-Path $target 'alt\meins.txt'))) 'Eine Liste ohne Kennzeile wird nicht befolgt'
Check ((Get-Content -LiteralPath $manifest -TotalCount 1) -ceq 'WidgetTea installed files 1') 'Danach liegt dort wieder die Liste des Setups'

Start-Process -FilePath (Join-Path $target 'uninstall.exe') -ArgumentList '/S' -Wait
Wait-Gone (Join-Path $target 'uninstall.exe')
$left = @(Get-ChildItem -LiteralPath $target -Recurse -File | ForEach-Object { $_.FullName.Substring($target.Length + 1) })
Write-Host "       Übrig: $($left -join ', ')"
Check (-not (Compare-Object -ReferenceObject @('alt\meins.txt', 'meine.dll') -DifferenceObject $left)) 'Nach der Deinstallation liegen dort nur noch die fremden Dateien'
Check (-not (Test-Path $regKey)) 'Die Registry-Einträge sind weg'

Write-Host "`nAlle Installer-Prüfungen bestanden." -ForegroundColor Green
