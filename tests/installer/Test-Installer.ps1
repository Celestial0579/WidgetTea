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
        [int]$TimeoutSec = 300
    )
    Write-Host "   >   $(Split-Path $Exe -Leaf) $($Arguments -join ' ')"
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -PassThru
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

# Fremde Dateien: Wer in einen Ordner mit eigenen Dingen installiert hat, darf sie beim Update nicht verlieren.
Set-Content -LiteralPath (Join-Path $dir 'meine-notizen.txt') -Value 'gehört nicht zu WidgetTea' -Encoding utf8
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
$expectedFiles = @(@(Get-ChildItem -LiteralPath $publishDir -File | ForEach-Object Name) + 'LICENSE.txt', 'uninstall.exe', 'meine-notizen.txt' | Sort-Object)
$actualFiles = @(Get-ChildItem -LiteralPath $dir -File | ForEach-Object Name | Sort-Object)
Write-Host "       Hauptordner: $($actualFiles -join ', ')"
$unexpected = @(Compare-Object -ReferenceObject $expectedFiles -DifferenceObject $actualFiles | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" })
Check ($unexpected.Count -eq 0) "Im Hauptordner liegt genau das neue Programm und die fremde Datei (Abweichung: $($unexpected -join ', '))"
$subdirs = @(Get-ChildItem -LiteralPath $dir -Directory | ForEach-Object Name)
Check ($subdirs.Count -eq 1 -and $subdirs[0] -eq 'eigener-ordner') "Die Sprachordner der Laufzeit sind weg (übrig: $($subdirs -join ', '))"
Check (Test-Path (Join-Path $dir 'meine-notizen.txt')) 'Die fremde Datei im Hauptordner ist noch da'
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
Check (($left -join '|') -ceq 'eigener-ordner\daten.txt|meine-notizen.txt') 'Im Ordner liegen nur noch die fremden Dateien'
Check (Test-SameSnapshot $foreignBefore (Get-Snapshot (Join-Path $dir 'eigener-ordner'))) 'Der fremde Unterordner ist unverändert'
Check (-not (Test-Path $regKey)) 'Die Registry-Einträge sind weg'
Check (-not (Get-ItemProperty -Path $runKey -Name 'WidgetTea' -ErrorAction SilentlyContinue)) 'Der Autostart ist weg'
Check (-not (Test-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\WidgetTea.lnk'))) 'Die Verknüpfung im Startmenü ist weg'
Check (Test-Path -LiteralPath $settingsFile) 'Die Einstellungen des Nutzers bleiben liegen (Benutzerdaten nicht abgewählt)'

Write-Host "`nAlle Installer-Prüfungen bestanden." -ForegroundColor Green
