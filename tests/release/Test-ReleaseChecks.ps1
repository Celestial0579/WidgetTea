<#
.SYNOPSIS
  Prüft die Sperre von build\release.ps1 -Publish: Veröffentlicht wird nur der Stand, der auf origin als main liegt.

.DESCRIPTION
  Gebaut und veröffentlicht wird hier nichts. Das Skript legt in einem Wegwerf-Ordner eine Gegenstelle und
  Arbeitskopien an und prüft daran

    0         dass jedes Skript mit Umlauten mit der UTF-8-BOM beginnt (sonst liest Windows PowerShell 5.1 es falsch),
    1 bis 7   die Prüfung selbst (build\ReleaseChecks.ps1) in den Lagen, die beim Veröffentlichen vorkommen,
    8 bis 10  dass release.ps1 sie mit -Publish vor dem Bauen aufruft und ohne -Publish nicht.

  Für 8 bis 10 läuft eine Kopie von release.ps1 in einer Wegwerf-Arbeitskopie. Deren origin ist der Wegwerf-Ordner,
  und ihre Projektdatei lässt sich nicht bauen. Die Kopie kommt deshalb nie bis zum Veröffentlichen: Sie endet an
  der Sperre, an der Suche nach NSIS oder am Bauen.

  Gebraucht werden nur git und PowerShell (Windows PowerShell 5.1 oder PowerShell 7), das Skript läuft also auch unter Linux. Die eigene git-Konfiguration
  bleibt außen vor, angefasst wird nur der Wegwerf-Ordner.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $root 'build/ReleaseChecks.ps1')

# An diesem Stück ist die Meldung der Sperre zu erkennen.
$guardText = 'nur der aktuelle Stand von origin/main'
# So endet die Kopie von release.ps1, wenn die Sperre sie durchlässt.
$afterGuard = 'NSIS nicht gefunden|dotnet publish fehlgeschlagen'

$script:stage = ''
function Step([string]$text) { $script:stage = $text; Write-Host "`n== $text" -ForegroundColor Cyan }
function Ok([string]$text) { Write-Host "   ok  $text" -ForegroundColor Green }
function Note([string]$text) { Write-Host "   --  $text" -ForegroundColor Yellow }
function Check([bool]$condition, [string]$text) {
    if (-not $condition) { throw "[$script:stage] FEHLGESCHLAGEN: $text" }
    Ok $text
}

function Invoke-Git([string[]]$Arguments) {
    $out = & git @Arguments
    if ($LASTEXITCODE) { throw ('git {0} endete mit {1}' -f ($Arguments -join ' '), $LASTEXITCODE) }
    $out
}

function New-Clone([string]$Name) {
    $path = Join-Path $work $Name
    Invoke-Git @('clone', '--quiet', $origin, $path) | Out-Null
    $path
}

function Add-Commit([string]$Repo, [string]$Text) {
    Add-Content -LiteralPath (Join-Path $Repo 'datei.txt') -Value $Text
    Invoke-Git @('-C', $Repo, 'add', 'datei.txt') | Out-Null
    Invoke-Git @('-C', $Repo, 'commit', '--quiet', '-m', $Text) | Out-Null
    Invoke-Git @('-C', $Repo, 'rev-parse', 'HEAD')
}

function Push-Main([string]$Repo) {
    Invoke-Git @('-C', $Repo, 'push', '--quiet', 'origin', 'main') | Out-Null
}

function Get-Refusal([string]$Repo) {
    # Liefert die Meldung, mit der die Prüfung ablehnt, oder $null, wenn sie durchlässt.
    try { Assert-HeadIsRemoteBranch -Root $Repo; return $null }
    catch { return $_.Exception.Message }
}

function Get-ReleaseStop([string]$Script, [switch]$Publish) {
    # Lässt die Kopie von release.ps1 laufen und liefert die Meldung, mit der sie abbricht.
    try {
        & { Set-StrictMode -Off; if ($Publish) { & $Script -Publish } else { & $Script } } | Out-Null
        return $null
    }
    catch { return $_.Exception.Message }
}

$tempBase = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$work = Join-Path $tempBase ('widgettea-releasetest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
$origin = Join-Path $work 'origin.git'

# Eigene git-Konfiguration für den Lauf: feste Identität, keine Signatur, nichts vom Rechner.
$gitConfig = Join-Path $work 'gitconfig'
Set-Content -LiteralPath $gitConfig -Encoding ascii -Value @(
    '[user]'
    '    name = Release-Test'
    '    email = release-test@example.invalid'
    '[init]'
    '    defaultBranch = main'
    '[commit]'
    '    gpgsign = false'
    '[core]'
    '    autocrlf = false'
    '[safe]'
    '    directory = *'
)
$envNames = 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM'
$envBefore = @{}
foreach ($n in $envNames) { $envBefore[$n] = [Environment]::GetEnvironmentVariable($n) }

try {
    $env:GIT_CONFIG_GLOBAL = $gitConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'

    Invoke-Git @('init', '--quiet', '--bare', '--initial-branch=main', $origin) | Out-Null
    $seed = Join-Path $work 'saat'
    Invoke-Git @('init', '--quiet', '--initial-branch=main', $seed) | Out-Null
    Invoke-Git @('-C', $seed, 'remote', 'add', 'origin', $origin) | Out-Null
    $a = Add-Commit $seed 'A'
    Push-Main $seed

    # ---- Lesbarkeit für Windows PowerShell 5.1 ----

    Step '0  Skripte mit Umlauten beginnen mit der UTF-8-BOM'
    # Windows PowerShell 5.1 liest ein Skript ohne BOM als Windows-1252. Umlaute werden dann zu Zeichensalat, und
    # der Gedankenstrich wird zu einem Anführungszeichen, an dem das Skript mit einem Syntaxfehler scheitert.
    $scripts = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1' |
        Where-Object { $_.FullName -notmatch '[\\/](bin|obj|artifacts)[\\/]' })
    Check ($scripts.Count -ge 4) "PowerShell-Skripte gefunden: $($scripts.Count)"
    $withoutBom = @()
    foreach ($s in $scripts) {
        $bytes = [System.IO.File]::ReadAllBytes($s.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $nonAscii = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes) -match '[\x80-\xFF]'
        if ($nonAscii -and -not $hasBom) { $withoutBom += $s.FullName.Substring($root.Length + 1) }
    }
    foreach ($name in $withoutBom) { Write-Host "       ohne BOM: $name" }
    Check ($withoutBom.Count -eq 0) 'Kein Skript mit Umlauten ist ohne BOM'

    # ---- Die Prüfung selbst ----

    Step '1  Ausgecheckt ist der Stand von origin/main'
    $k1 = New-Clone 'k1'
    Check ($null -eq (Get-Refusal $k1)) 'Die Prüfung lässt durch'

    Step '2  Derselbe Commit ohne Zweig (abgetrennter HEAD)'
    Invoke-Git @('-C', $k1, 'checkout', '--quiet', '--detach') | Out-Null
    Check ($null -eq (Get-Refusal $k1)) 'Die Prüfung lässt durch: Es zählt der Commit, nicht der Name des Zweigs'

    Step '3  Eigener Commit, der noch nicht auf origin liegt'
    $k3 = New-Clone 'k3'
    $own = Add-Commit $k3 'eigener Commit'
    $msg = Get-Refusal $k3
    Check ($msg -and $msg.Contains($guardText)) 'Die Prüfung lehnt ab'
    Check ($msg.Contains($own.Substring(0, 7)) -and $msg.Contains($a.Substring(0, 7))) 'Die Meldung nennt beide Commits'

    Step '4  main ist ausgecheckt, aber nicht aktualisiert'
    $k4 = New-Clone 'k4'
    $b = Add-Commit $seed 'B'
    Push-Main $seed
    $marker = Invoke-Git @('-C', $k4, 'rev-parse', 'refs/remotes/origin/main')
    $head = Invoke-Git @('-C', $k4, 'rev-parse', 'HEAD')
    Check ($marker -eq $head) 'Der lokale Merker origin/main zeigt noch auf den alten Stand (an ihm fiele nichts auf)'
    $msg = Get-Refusal $k4
    Check ($msg -and $msg.Contains($guardText)) 'Die Prüfung lehnt trotzdem ab: Sie fragt die Gegenstelle'
    Check ($msg.Contains($b.Substring(0, 7))) 'Die Meldung nennt den Stand der Gegenstelle'

    Step '5  Ein anderer Zweig ist ausgecheckt'
    $k5 = New-Clone 'k5'
    Invoke-Git @('-C', $k5, 'checkout', '--quiet', '-b', 'mein-zweig') | Out-Null
    Add-Commit $k5 'Arbeit auf dem Zweig' | Out-Null
    $msg = Get-Refusal $k5
    Check ($msg -and $msg.Contains($guardText)) 'Die Prüfung lehnt ab'
    Check ($msg.Contains('Zweig mein-zweig')) 'Die Meldung nennt den Zweig'

    Step '6  Die Gegenstelle ist nicht erreichbar'
    $k6 = New-Clone 'k6'
    Invoke-Git @('-C', $k6, 'remote', 'set-url', 'origin', (Join-Path $work 'gibt-es-nicht.git')) | Out-Null
    Note 'Die folgende Fehlermeldung von git gehört zur Prüfung.'
    $msg = Get-Refusal $k6
    Check ($msg -and $msg.Contains('nicht abfragen')) 'Die Prüfung lehnt ab, statt ohne Antwort zu veröffentlichen'

    Step '7  Die Gegenstelle hat keinen Zweig main'
    $empty = Join-Path $work 'leer.git'
    Invoke-Git @('init', '--quiet', '--bare', '--initial-branch=main', $empty) | Out-Null
    Invoke-Git @('-C', $k6, 'remote', 'set-url', 'origin', $empty) | Out-Null
    $msg = Get-Refusal $k6
    Check ($msg -and $msg.Contains('keinen Zweig main')) 'Die Prüfung lehnt ab'

    # ---- release.ps1 selbst, als Kopie in einer Wegwerf-Arbeitskopie ----

    $copy = New-Clone 'release-kopie'
    New-Item -ItemType Directory -Path (Join-Path $copy 'build') | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'build/release.ps1'), (Join-Path $root 'build/ReleaseChecks.ps1') -Destination (Join-Path $copy 'build')
    Set-Content -LiteralPath (Join-Path $copy 'WidgetTea.csproj') -Encoding ascii -Value @(
        '<Project>'
        '  <PropertyGroup>'
        '    <Version>9.9.9</Version>'
        '    <UpdateRepository>https://example.invalid/kein/github</UpdateRepository>'
        '  </PropertyGroup>'
        '</Project>'
    )
    $release = Join-Path $copy 'build/release.ps1'

    Step '8  release.ps1 -Publish auf dem Stand von origin/main'
    $msg = Get-ReleaseStop $release -Publish
    Check ($msg -and -not $msg.Contains($guardText)) 'Die Sperre lässt durch'
    Check ($msg -match $afterGuard) "Die Kopie endet erst danach: $msg"

    Step '9  release.ps1 -Publish auf einem veralteten Stand'
    Add-Commit $seed 'C' | Out-Null
    Push-Main $seed
    $msg = Get-ReleaseStop $release -Publish
    Check ($msg -and $msg.Contains($guardText)) 'release.ps1 bricht an der Sperre ab, bevor es NSIS sucht oder baut'
    $tags = @(Invoke-Git @('-C', $copy, 'tag', '--list'))
    Check ($tags.Count -eq 0) 'Es gibt keinen Tag'

    Step '10 release.ps1 ohne -Publish auf demselben veralteten Stand'
    $msg = Get-ReleaseStop $release
    Check ($msg -and -not $msg.Contains($guardText)) 'Ohne -Publish greift die Sperre nicht: Bauen darf man jeden Stand'
    Check ($msg -match $afterGuard) "Die Kopie endet wie beim Bauen ohne Werkzeug: $msg"

    Write-Host "`nAlle Release-Prüfungen bestanden." -ForegroundColor Green
}
finally {
    foreach ($n in $envNames) { [Environment]::SetEnvironmentVariable($n, $envBefore[$n]) }
    try { Remove-Item -LiteralPath $work -Recurse -Force }
    catch { Write-Host "   --  Der Wegwerf-Ordner blieb liegen: $work" -ForegroundColor Yellow }
}

# In 8 und 10 darf die Kopie von release.ps1 am Bauen scheitern. Ohne diese Zeile bliebe dessen Exitcode stehen,
# und der Schritt in der CI gälte als gescheitert, obwohl alle Prüfungen bestanden sind.
exit 0
