<#
.SYNOPSIS
  Prüft auf einem ARM64-Windows, was dort anders ist: Das Setup sucht die x64-Laufzeit an ihrem eigenen Ort,
  winget muss ausdrücklich die x64-Fassung holen, und die App läuft in der x64-Emulation.

.DESCRIPTION
  Gedacht für die CI (windows-11-arm). Voraussetzung ist ein Lauf von build\release.ps1 ohne -Publish.

  ACHTUNG: Das Skript installiert die .NET Desktop Runtime (x64) über winget, falls sie fehlt, und installiert und
  deinstalliert WidgetTea für den angemeldeten Benutzer. Außerhalb der CI läuft es deshalb nur mit -Force.

  Was geprüft wird:
    1  Reicht die x64-Laufzeit nicht, endet /S mit Exitcode 3 und installiert nichts, auch wenn die
       ARM64-Laufzeit vorhanden und neu genug ist.
    2  Der winget-Aufruf des Setups (aus installer\DotnetRuntime.nsh gelesen) holt die x64-Laufzeit.
    3  Danach installiert /S, und die App lädt coreclr.dll aus dotnet\x64.

  Bringt der Rechner die x64-Laufzeit schon mit, verlangt eine Testfassung des Setups so viel wie die
  ARM64-Laufzeit hergibt; ist die x64-Laufzeit älter als die, „reicht sie nicht", und 1 und 2 laufen trotzdem.
  Sonst entfallen sie.

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
    throw 'Dieses Skript installiert die .NET-Laufzeit und WidgetTea für den angemeldeten Benutzer. Außerhalb der CI nur mit -Force.'
}
$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
if ("$arch" -ne 'Arm64') { throw "Dieses Skript ist für ARM64-Windows gedacht, hier läuft $arch." }

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
[xml]$proj = Get-Content (Join-Path $root 'WidgetTea.csproj')
$version = $proj.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
$setup = Join-Path $root "artifacts\$version\WidgetTea-$version-setup.exe"
$logs = Join-Path $root 'artifacts\test-logs'
# Der Arbeitsordner, und mit ihm der Installationsordner, liegt außerhalb des Profils direkt unter der Laufwerkswurzel,
# wie bei den Prüfungen auf x64. Dort prüft das Setup auch jeden Ordner darüber (GHSA-39vg-vcch-v4vj), also bekommt er
# feste Rechte (New-ClosedDir), statt zu erben, was der Runner vorgibt.
$work = Join-Path "$env:SystemDrive\" 'widgettea-arm64'
$target = Join-Path $work 'installiert'
$setupLog = Join-Path ([System.IO.Path]::GetTempPath()) 'WidgetTea-Setup.log'   # schreibt das Setup bei einem stillen Abbruch
$regKey = 'HKCU:\Software\Celestial0579\WidgetTea'
$x64Desktop = Join-Path $env:ProgramFiles 'dotnet\x64\shared\Microsoft.WindowsDesktop.App'
$armDesktop = Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.WindowsDesktop.App'

if (-not (Test-Path $setup)) { throw "Setup fehlt: $setup – erst build\release.ps1 laufen lassen." }
if (((Test-Path $regKey) -or (Test-Path 'HKCU:\Software\WidgetTea')) -and -not $Force) { throw "WidgetTea ist auf diesem Rechner schon installiert ($regKey). Abbruch." }
# Vollzugriff nur für den Benutzer, SYSTEM und die Administratoren, nichts geerbt; wie in Test-Installer.ps1.
# Auf dem ARM64-Runner lehnte das Setup einen so vorbereiteten Ordner ab, weil Authenticated Users ihn ändern durfte.
# Deshalb entfernt der Helfer nach icacls jeden Eintrag eines anderen Kontos einzeln, und zum Schluss muss die Liste
# genau so aussehen. Musste er etwas entfernen, stehen im Protokoll die Rechte beim Anlegen und nach icacls.
function New-ClosedDir([string]$Path) {
    New-Item -ItemType Directory -Force $Path | Out-Null
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $keep = @($me, 'S-1-5-18', 'S-1-5-32-544')
    $sidType = [System.Security.Principal.SecurityIdentifier]
    $icacls = "$env:SystemRoot\System32\icacls.exe"
    $created = (Get-Acl -LiteralPath $Path).Sddl
    & $icacls $Path /inheritance:r /grant:r "*${me}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /Q | Out-Null
    if ($LASTEXITCODE) { throw "icacls /grant:r für $Path fehlgeschlagen ($LASTEXITCODE)" }
    $afterIcacls = Get-Acl -LiteralPath $Path
    $others = @($afterIcacls.GetAccessRules($true, $true, $sidType) |
        ForEach-Object { $_.IdentityReference.Value } | Where-Object { $_ -notin $keep } | Select-Object -Unique)
    foreach ($sid in $others) {
        & $icacls $Path /remove "*$sid" /Q | Out-Null
        if ($LASTEXITCODE) { throw "icacls /remove für $sid an $Path fehlgeschlagen ($LASTEXITCODE)" }
    }
    if ($others.Count) { Write-Host "  ${Path}: Einträge anderer Konten entfernt ($($others -join ', ')); angelegt mit $created, nach icacls $($afterIcacls.Sddl)" }
    $acl = Get-Acl -LiteralPath $Path
    $left = @($acl.GetAccessRules($true, $true, $sidType) | Where-Object { $_.IdentityReference.Value -notin $keep })
    if (-not $acl.AreAccessRulesProtected -or $left.Count) { throw "$Path hat nicht die festen Rechte: $($acl.Sddl)" }
}

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-ClosedDir $work
New-Item -ItemType Directory -Force $logs | Out-Null

$script:stage = ''
function Step([string]$text) { $script:stage = $text; Write-Host "`n== $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "   ok  $text" -ForegroundColor Green }
function Note([string]$text) { Write-Host "   --  $text" -ForegroundColor Yellow }
function Check([bool]$condition, [string]$text) {
    if (-not $condition) { throw "[$script:stage] FEHLGESCHLAGEN: $text" }
    Ok $text
}

# Höchste Patchnummer einer 10.0-Laufzeit im angegebenen Ordner, oder -1.
function Get-Patch([string]$Folder) {
    $patches = @(Get-ChildItem -LiteralPath $Folder -Directory -Filter '10.0.*' -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.Name -match '^10\.0\.(\d+)$') { [int]$Matches[1] } })
    if ($patches.Count -eq 0) { return -1 }
    ($patches | Measure-Object -Maximum).Maximum
}

function Invoke-SetupSilently([string]$Exe) {
    Remove-Item -LiteralPath $setupLog -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $Exe -ArgumentList '/S', "/D=$target" -PassThru -Wait
    # Bricht das Setup still ab, steht der Grund in seinem Protokoll.
    if (Test-Path -LiteralPath $setupLog) {
        Get-Content -LiteralPath $setupLog | ForEach-Object { Write-Host "  Setup: $_" }
        Copy-Item -LiteralPath $setupLog -Destination (Join-Path $logs 'setup-abbruch.log') -Force
    }
    $p.ExitCode
}

# Die Mindestversion und der winget-Aufruf, wie sie im Setup stehen.
$nsi = Get-Content -LiteralPath (Join-Path $root 'installer\WidgetTea.nsi') -Raw
$nsh = Get-Content -LiteralPath (Join-Path $root 'installer\DotnetRuntime.nsh') -Raw
if ($nsi -notmatch '(?m)^\s*!define DOTNET_MINPATCH\s+(\d+)') { throw 'DOTNET_MINPATCH nicht gefunden' }
$minPatch = [int]$Matches[1]
if ($nsi -notmatch '(?m)^\s*!define DOTNET_WINGET\s+"([^"]+)"') { throw 'DOTNET_WINGET nicht gefunden' }
$package = $Matches[1]
if ($nsh -notmatch '"\$\{DOTNET_WINGET_EXE\}" (install [^'']+)''') { throw 'winget-Aufruf in DotnetRuntime.nsh nicht gefunden' }
$wingetArguments = $Matches[1].Replace('${DOTNET_WINGET}', $package)

Step '0 Ausgangslage'
$armPatch = Get-Patch $armDesktop
$x64Patch = Get-Patch $x64Desktop
Write-Host "       Windows: $arch, Prozess: $([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
Write-Host "       Desktop Runtime ARM64: 10.0.$armPatch   x64: 10.0.$x64Patch   (-1 = fehlt)"
Write-Host "       Das Setup verlangt x64 ab 10.0.$minPatch und ruft auf: winget $wingetArguments"
Check ($wingetArguments -match '--architecture x64') 'Der winget-Aufruf des Setups verlangt ausdrücklich x64'

# Welches Setup die Prüfung nimmt und wie viel es verlangt. Reicht die x64-Laufzeit dem gebauten Setup schon, verlangt
# eine Testfassung so viel, wie die ARM64-Laufzeit hergibt. Ist die x64-Laufzeit älter, gibt es damit die Lage, um
# die es geht: x64 reicht nicht, ARM64 würde reichen, darf aber nicht zählen.
$testSetup = $setup
$need = $minPatch
if ($x64Patch -ge $minPatch -and $armPatch -gt $x64Patch) {
    $need = $armPatch
    $makensis = @("${env:ProgramFiles(x86)}\NSIS\makensis.exe", "$env:ProgramFiles\NSIS\makensis.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $makensis) { throw 'NSIS nicht gefunden' }
    $testSetup = Join-Path $work 'WidgetTea-verlangt-mehr-setup.exe'
    & $makensis /V2 /INPUTCHARSET UTF8 "/DVERSION=$version" "/DSRCDIR=$(Join-Path $root "artifacts\$version\publish")" "/DOUTFILE=$testSetup" `
        "/DDOTNET_MINPATCH=$need" (Join-Path $root 'installer\WidgetTea.nsi') | Out-Null
    if ($LASTEXITCODE) { throw 'makensis (Testfassung) fehlgeschlagen' }
    Ok "Testfassung des Setups gebaut: verlangt x64 ab 10.0.$need"
}

if ($x64Patch -lt $need) {
    Step "1 /S, die x64-Laufzeit reicht nicht (verlangt 10.0.$need, vorhanden 10.0.$x64Patch)"
    if ($armPatch -ge $need) { Note "Die ARM64-Laufzeit 10.0.$armPatch würde reichen; das Setup darf sie nicht für die gesuchte halten" }
    $code = Invoke-SetupSilently $testSetup
    Check ($code -eq 3) "Exitcode 3 (war $code)"
    Check (-not (Test-Path $target)) 'Installiert wurde nichts'

    Step '2 Der winget-Aufruf des Setups holt die x64-Laufzeit'
    $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (-not (Test-Path -LiteralPath $winget)) {
        # Auf einem CI-Runner ist winget für das Konto mitunter nicht eingerichtet, obwohl Windows es mitbringt.
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop }
        catch { Note "winget ließ sich nicht einrichten: $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $winget) {
        $out = Join-Path $logs 'winget-arm64.log'
        $p = Start-Process -FilePath $winget -ArgumentList $wingetArguments -PassThru -Wait -NoNewWindow -RedirectStandardOutput $out
        Get-Content -LiteralPath $out -ErrorAction SilentlyContinue | Where-Object { $_.Trim().Length -gt 3 } | Select-Object -Last 6 | ForEach-Object { Write-Host "       winget: $_" }
        Write-Host "       winget endete mit $($p.ExitCode); x64 jetzt 10.0.$(Get-Patch $x64Desktop)"
        Check ((Get-Patch $x64Desktop) -ge $need) "Die x64-Laufzeit reicht jetzt: 10.0.$(Get-Patch $x64Desktop) unter dotnet\x64"
    } elseif ($x64Patch -ge $minPatch) {
        Note 'winget fehlt auf diesem Rechner; der winget-Aufruf des Setups ist hier nicht zu prüfen'
        Note "Weiter mit dem gebauten Setup, dem die vorhandene x64-Laufzeit 10.0.$x64Patch reicht"
        $testSetup = $setup
    } else {
        throw "[$script:stage] Die x64-Laufzeit reicht nicht, und winget fehlt: Auf diesem Rechner lässt sich nicht weiterprüfen."
    }
} else {
    Note "Die x64-Laufzeit reicht schon (10.0.$x64Patch) und ist nicht älter als die ARM64-Laufzeit; 1 und 2 entfallen"
}

Step '3 Installation und Start der App'
$code = Invoke-SetupSilently $testSetup
Check ($code -eq 0) "Exitcode 0 (war $code)"
$exe = Join-Path $target 'WidgetTea.exe'
Check (Test-Path $exe) 'WidgetTea.exe ist da'
$trace = Join-Path $logs 'corehost-arm64.log'
# Der CI-Job setzt DOTNET_ROOT auf die ARM64-Laufzeit (actions/setup-dotnet). Ein x64-Programm nähme sie von dort
# und scheiterte an der falschen Architektur. Auf einem gewöhnlichen Rechner ist die Variable nicht gesetzt, also
# startet die App hier ohne sie.
$dotnetRoot = $env:DOTNET_ROOT
if ($dotnetRoot) { Note "DOTNET_ROOT ($dotnetRoot) gilt für den Start der App nicht" }
$env:DOTNET_ROOT = $null
$env:COREHOST_TRACE = '1'
$env:COREHOST_TRACEFILE = $trace
try { $app = Start-Process -FilePath $exe -PassThru } finally {
    Remove-Item Env:COREHOST_TRACE, Env:COREHOST_TRACEFILE -ErrorAction SilentlyContinue
    $env:DOTNET_ROOT = $dotnetRoot
}
$coreclr = $null
$deadline = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $deadline -and -not $coreclr) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $trace) {
        # Der Starter nennt coreclr.dll erst an Orten, an denen er nur nachsieht. Gesucht ist die geladene Laufzeit,
        # und die liegt unter shared\Microsoft.NETCore.App\<Version>.
        $hit = Select-String -LiteralPath $trace -Pattern '[A-Za-z]:\\[^\r\n\]]*\\shared\\Microsoft\.NETCore\.App\\[^\\\r\n\]]+\\coreclr\.dll' -AllMatches | Select-Object -First 1
        if ($hit) { $coreclr = $hit.Matches[0].Value }
    }
}
$alive = -not $app.HasExited
Get-Process -Name 'WidgetTea' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Host "       Laufzeit: $coreclr"
Check ([bool]$coreclr -and $coreclr -match '\\dotnet\\x64\\shared\\Microsoft\.NETCore\.App\\10\.0\.\d+\\coreclr\.dll$') 'Die App lädt die x64-Laufzeit aus dotnet\x64'
if ($alive) { Ok 'Die App lief, bis die Prüfung sie beendet hat' } else { Note "Die App hat sich selbst beendet (Exitcode $($app.ExitCode))" }

Start-Process -FilePath (Join-Path $target 'uninstall.exe') -ArgumentList '/S' -Wait
$deadline = (Get-Date).AddSeconds(60)
while ((Test-Path $target) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
Check (-not (Test-Path $target)) 'Die Deinstallation entfernt den Ordner'

Write-Host "`nAlle ARM64-Prüfungen bestanden." -ForegroundColor Green
exit 0
