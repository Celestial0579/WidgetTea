<#
.SYNOPSIS
  Prüft das Selbst-Update so, wie die App es auslöst: Sie fragt ihre Update-Quelle, lädt das Setup, prüft die
  Prüfsumme, startet es mit /S /RESTART und beendet sich.

.DESCRIPTION
  Gedacht für die CI (windows-latest). Die Update-Quelle ist hier nicht GitHub, sondern ein kleiner Server auf
  diesem Rechner, der sich wie ein Gitea verhält. Dafür baut das Skript die App zweimal mit dieser Quelle als
  <UpdateRepository>: einmal in der Version aus WidgetTea.csproj und einmal als 9.9.9, das „neuere Release".

  ACHTUNG: Das Skript installiert und deinstalliert WidgetTea für den angemeldeten Benutzer und überschreibt dessen
  Einstellungen unter %LOCALAPPDATA%\WidgetTea. Außerhalb der CI läuft es deshalb nur mit -Force. Es braucht
  Administratorrechte (für den Server), das .NET SDK und NSIS.

  Was geprüft wird:
    1  Das Update gelingt: Die laufende App lädt das angebotene Setup genau einmal, danach läuft die neue Version,
       vom Setup gestartet, und der Vermerk über den begonnenen Versuch ist wieder weg.
    2  Das Setup scheitert (hier: ein Programm, das sich sofort mit einem Fehler beendet). Die App hat sich dafür
       beendet und bleibt zu. Nach dem nächsten Start fragt sie wieder nach Updates, lädt dasselbe Update aber
       nicht noch einmal und läuft weiter. Ohne den Vermerk schlösse sie sich eine Minute nach jedem Start.

  Die App sucht eine Minute nach dem Start zum ersten Mal nach Updates; daher die Wartezeiten.

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
$newVersion = '9.9.9'
$work = Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }) 'widgettea-selbstupdate'
$logs = Join-Path $root 'artifacts\test-logs'
$serve = Join-Path $work 'server'
$requests = Join-Path $serve 'anfragen.log'
$target = Join-Path $work 'installiert'
$targetExe = Join-Path $target 'WidgetTea.exe'
$settingsDir = Join-Path $env:LOCALAPPDATA 'WidgetTea'
$attemptFile = Join-Path $settingsDir 'update-attempt.json'
$regKey = 'HKCU:\Software\WidgetTea'

if ((Test-Path $regKey) -and -not $Force) { throw "WidgetTea ist auf diesem Rechner schon installiert ($regKey). Abbruch." }
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work, $serve, $logs | Out-Null

$script:stage = ''
function Step([string]$text) { $script:stage = $text; Write-Host "`n== $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "   ok  $text" -ForegroundColor Green }
function Note([string]$text) { Write-Host "   --  $text" -ForegroundColor Yellow }
function Check([bool]$condition, [string]$text) {
    if (-not $condition) { throw "[$script:stage] FEHLGESCHLAGEN: $text" }
    Ok $text
}

# Prozesse der App aus dem Installationsordner. Beim Aufruf in @( ) setzen.
function Get-App { Get-Process -Name 'WidgetTea' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $targetExe } }
function Stop-App {
    Get-App | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
}
function Start-App {
    Stop-App
    Start-Process -FilePath $targetExe | Out-Null
    Start-Sleep -Seconds 2
    if (@(Get-App).Count -eq 0) { throw "[$script:stage] Die App läuft nach dem Start nicht" }
}
function Get-Requests([string]$Pattern) {
    if (-not (Test-Path -LiteralPath $requests)) { return }
    Get-Content -LiteralPath $requests | Where-Object { $_ -match $Pattern }
}
# Wartet, bis die Bedingung gilt. Ein Fehler darin zählt als „noch nicht": Während das Setup arbeitet, ist etwa
# die EXE kurz weg oder gesperrt.
function Wait-Until([scriptblock]$Condition, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { if (& $Condition) { return $true } } catch { }
        Start-Sleep -Milliseconds 500
    }
    $false
}
function Invoke-Checked([string]$What, [scriptblock]$Call) {
    & $Call | Out-Null
    if ($LASTEXITCODE) { throw "$What ist gescheitert (Exitcode $LASTEXITCODE)" }
}
# Was der Server als neuestes Release anbietet: Version 9.9.9 mit dem angegebenen Setup.
function Set-Offer([string]$SetupFile) {
    Copy-Item -LiteralPath $SetupFile -Destination (Join-Path $serve 'setup.exe') -Force
    $hash = (Get-FileHash -LiteralPath $SetupFile -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath (Join-Path $serve 'setup.exe.sha256') -Value "$hash  WidgetTea-$newVersion-setup.exe" -Encoding ascii -NoNewline
    Remove-Item -LiteralPath $requests -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 0 Vorbereitung

Step '0 Vorbereitung'
$probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = $probe.LocalEndpoint.Port
$probe.Stop()
$base = "http://127.0.0.1:$port"
$repository = "$base/pruefung/widgettea"

$makensis = @("${env:ProgramFiles(x86)}\NSIS\makensis.exe", "$env:ProgramFiles\NSIS\makensis.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $makensis) { throw 'NSIS nicht gefunden' }
$csproj = Join-Path $root 'WidgetTea.csproj'
$nsi = Join-Path $root 'installer\WidgetTea.nsi'

# Die App zweimal, beide mit dem lokalen Server als Update-Quelle.
$payloadOld = Join-Path $work 'programm-alt'
$payloadNew = Join-Path $work 'programm-neu'
Invoke-Checked 'dotnet publish (bisherige Version)' {
    dotnet publish $csproj -c Release -r win-x64 --self-contained false "-p:UpdateRepository=$repository" -p:DebugType=none -o $payloadOld
}
Invoke-Checked 'dotnet publish (neue Version)' {
    dotnet publish $csproj -c Release -r win-x64 --self-contained false "-p:UpdateRepository=$repository" "-p:Version=$newVersion" -p:DebugType=none -o $payloadNew
}
$setupOld = Join-Path $work "WidgetTea-$version-setup.exe"
$setupNew = Join-Path $work "WidgetTea-$newVersion-setup.exe"
Invoke-Checked 'makensis (bisherige Version)' { & $makensis /V2 /INPUTCHARSET UTF8 "/DVERSION=$version" "/DSRCDIR=$payloadOld" "/DOUTFILE=$setupOld" $nsi }
Invoke-Checked 'makensis (neue Version)' { & $makensis /V2 /INPUTCHARSET UTF8 "/DVERSION=$newVersion" "/DSRCDIR=$payloadNew" "/DOUTFILE=$setupNew" $nsi }
Ok "App und Setup gebaut: $version und $newVersion, Update-Quelle $repository"

# Ein „Setup", das sofort scheitert.
$csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { throw 'csc.exe von .NET Framework 4 fehlt' }
$setupBroken = Join-Path $work 'kaputtes-setup.exe'
Set-Content -LiteralPath (Join-Path $work 'kaputt.cs') -Encoding ascii -Value 'public static class Kaputt { public static int Main() { return 1; } }'
Invoke-Checked 'csc (kaputtes Setup)' { & $csc /nologo "/out:$setupBroken" (Join-Path $work 'kaputt.cs') }

# Der Server: antwortet wie ein Gitea auf die Frage nach dem neuesten Release, liefert Setup und Prüfsumme und
# schreibt jede Anfrage auf.
Set-Content -LiteralPath (Join-Path $serve 'release.json') -Encoding ascii -Value @"
{"tag_name": "v$newVersion", "html_url": "$repository/releases/tag/v$newVersion", "draft": false, "prerelease": false,
 "assets": [
   {"name": "WidgetTea-$newVersion-setup.exe", "browser_download_url": "$base/dl/setup.exe"},
   {"name": "WidgetTea-$newVersion-setup.exe.sha256", "browser_download_url": "$base/dl/setup.exe.sha256"} ]}
"@
Set-Content -LiteralPath (Join-Path $serve 'heatmap.json') -Encoding ascii -Value '[{"timestamp": 1762948800, "contributions": 3}]'
$serverScript = Join-Path $work 'server.ps1'
Set-Content -LiteralPath $serverScript -Encoding ascii -Value @'
param([int]$Port, [string]$Root)
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
while ($listener.IsListening) {
    $context = $listener.GetContext()
    $path = $context.Request.Url.AbsolutePath
    Add-Content -LiteralPath (Join-Path $Root 'anfragen.log') -Value $path
    $file = $null
    if ($path -match '/releases/latest$') { $file = 'release.json' }
    elseif ($path -eq '/dl/setup.exe') { $file = 'setup.exe' }
    elseif ($path -eq '/dl/setup.exe.sha256') { $file = 'setup.exe.sha256' }
    elseif ($path -match '/heatmap$') { $file = 'heatmap.json' }
    try {
        if ($file -and (Test-Path -LiteralPath (Join-Path $Root $file))) {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $Root $file))
            if ($file -like '*.json') { $context.Response.ContentType = 'application/json' }
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $context.Response.StatusCode = 404
        }
        $context.Response.Close()
    } catch { }
}
'@
$server = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-File', $serverScript, '-Port', $port, '-Root', $serve -PassThru -WindowStyle Hidden
$answered = Wait-Until { try { (Invoke-WebRequest -Uri "$base/api/v1/repos/pruefung/widgettea/releases/latest" -UseBasicParsing).StatusCode -eq 200 } catch { $false } } 30
Check $answered "Der Update-Server antwortet auf $base"

try {
    # Einstellungen, mit denen die App ohne Einstellungsfenster startet: vollständig, automatische Updates an, und
    # eine Datei an der Stelle des Tokens (ihr Inhalt ist keines; die App fragt dann ohne Token).
    New-Item -ItemType Directory -Force $settingsDir | Out-Null
    $settings = @(
        '{'
        "  `"baseUrl`": `"$base`","
        '  "username": "pruefung",'
        '  "refreshMinutes": 15,'
        '  "timeoutSeconds": 10,'
        '  "ignoreCertificateErrors": false,'
        '  "autoUpdate": true,'
        '  "left": null,'
        '  "top": null,'
        '  "locked": false'
        '}'
    ) -join "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $settingsDir 'settings.json'), $settings, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllBytes((Join-Path $settingsDir 'credentials.bin'), [byte[]](1..16))
    Remove-Item -LiteralPath $attemptFile, (Join-Path $settingsDir 'autoupdate-paused') -ErrorAction SilentlyContinue

    # ------------------------------------------------------------ 1 Das Update gelingt

    Step "1 Die App aktualisiert sich selbst von $version auf $newVersion"
    Start-Process -FilePath $setupOld -ArgumentList '/S', "/D=$target" -Wait
    Check ((Get-Item $targetExe).VersionInfo.ProductVersion -like "$version*") "Installiert ist $version"
    Set-Offer $setupNew
    Start-App
    Write-Host '       Die App sucht eine Minute nach dem Start nach Updates ...'
    $updated = Wait-Until { (Test-Path $targetExe) -and (Get-Item $targetExe).VersionInfo.ProductVersion -like "$newVersion*" -and @(Get-App).Count -gt 0 } 180
    Check $updated "Danach ist $newVersion installiert und läuft, vom Setup gestartet"
    Check (@(Get-Requests '/releases/latest$').Count -ge 1) 'Die App hat ihre Update-Quelle gefragt'
    Check (@(Get-Requests '^/dl/setup\.exe$').Count -eq 1) 'Sie hat das Setup genau einmal geladen'
    Check (@(Get-Requests '^/dl/setup\.exe\.sha256$').Count -eq 1) 'und dessen Prüfsumme'
    Check (@(Get-Requests '/heatmap$').Count -ge 1) 'Nebenbei: Die Heatmap wurde abgefragt'
    $cleared = Wait-Until { -not (Test-Path -LiteralPath $attemptFile) } 20
    Check $cleared 'Der Vermerk über den begonnenen Versuch ist wieder weg'
    Stop-App

    # ------------------------------------------------------------ 2 Das Setup scheitert

    Step '2 Das Setup scheitert: kein zweiter Versuch nach dem nächsten Start'
    Start-Process -FilePath $setupOld -ArgumentList '/S', "/D=$target" -Wait
    Check ((Get-Item $targetExe).VersionInfo.ProductVersion -like "$version*") "Installiert ist wieder $version"
    Remove-Item -LiteralPath $attemptFile -ErrorAction SilentlyContinue
    Set-Offer $setupBroken
    Start-App
    Write-Host '       Die App sucht eine Minute nach dem Start nach Updates ...'
    $closed = Wait-Until { @(Get-Requests '^/dl/setup\.exe$').Count -ge 1 -and @(Get-App).Count -eq 0 } 180
    Check $closed 'Die App hat das Setup geladen, gestartet und sich dafür beendet'
    Start-Sleep -Seconds 3
    Check (@(Get-App).Count -eq 0) 'Das gescheiterte Setup hat sie nicht wieder gestartet: Das Widget ist zu'
    Check (Test-Path -LiteralPath $attemptFile) 'Der begonnene Versuch ist vermerkt'
    $attempt = Get-Content -LiteralPath $attemptFile -Raw | ConvertFrom-Json
    Check ($attempt.Version -eq $newVersion -and $attempt.Count -eq 1) "Vermerkt ist Version $($attempt.Version), Versuch $($attempt.Count)"

    # Der nächste Start, etwa die nächste Anmeldung.
    $checksBefore = @(Get-Requests '/releases/latest$').Count
    Start-App
    Write-Host '       Wieder eine Minute bis zur Suche nach Updates ...'
    $asked = Wait-Until { @(Get-Requests '/releases/latest$').Count -gt $checksBefore } 180
    Check $asked 'Die App hat wieder nach Updates gefragt'
    Start-Sleep -Seconds 15
    Check (@(Get-Requests '^/dl/setup\.exe$').Count -eq 1) 'Sie hat dasselbe Update nicht noch einmal geladen'
    Check (@(Get-App).Count -gt 0) 'Sie läuft weiter'
    Check ((Get-Item $targetExe).VersionInfo.ProductVersion -like "$version*") "Installiert ist weiter $version"
    Stop-App
}
finally {
    Stop-App
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $requests) { Copy-Item -LiteralPath $requests -Destination (Join-Path $logs 'selbstupdate-anfragen.log') -Force }
    if (Test-Path (Join-Path $target 'uninstall.exe')) {
        Start-Process -FilePath (Join-Path $target 'uninstall.exe') -ArgumentList '/S' -Wait
    }
}

Write-Host "`nAlle Selbst-Update-Prüfungen bestanden." -ForegroundColor Green
exit 0
