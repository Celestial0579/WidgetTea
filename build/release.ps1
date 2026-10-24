<#
.SYNOPSIS
  Baut WidgetTea (self-contained, win-x64), erzeugt das NSIS-Setup samt SHA-256 und veröffentlicht es
  optional als GitHub-Release.

.DESCRIPTION
  Versionsnummer und Update-Repository kommen aus WidgetTea.csproj (<Version>, <UpdateRepository>).
  Für ein neues Release: <Version> erhöhen, committen, pushen, dann

    .\build\release.ps1 -Publish

  -Publish legt den Tag v<Version> an, pusht ihn und erstellt per gh-CLI das Release mit beiden Assets:
    WidgetTea-<ver>-setup.exe
    WidgetTea-<ver>-setup.exe.sha256
  Ein Gitea-Spiegel des Repos übernimmt Code und Tags beim nächsten Abgleich,
  die Release-Assets nicht – der Updater lädt immer von GitHub.

.PARAMETER Repository
  Überschreibt <UpdateRepository> (z.B. für Tests gegen einen lokalen Server).
#>
[CmdletBinding()]
param(
    [switch]$Publish,
    [string]$Repository
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$csproj = Join-Path $root 'WidgetTea.csproj'
[xml]$proj = Get-Content $csproj
$version = $proj.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
if (-not $Repository) {
    $Repository = $proj.Project.PropertyGroup.UpdateRepository | Where-Object { $_ } | Select-Object -First 1
}
$Repository = "$Repository".TrimEnd('/')
if (-not $version) { throw "<Version> fehlt in WidgetTea.csproj" }

$makensis = @("${env:ProgramFiles(x86)}\NSIS\makensis.exe", "$env:ProgramFiles\NSIS\makensis.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $makensis) { throw "NSIS nicht gefunden (winget install NSIS.NSIS)" }

$out = Join-Path $root "artifacts\$version"
$publishDir = Join-Path $out 'publish'
$setupName = "WidgetTea-$version-setup.exe"
$setup = Join-Path $out $setupName
if (Test-Path $out) { Remove-Item -Recurse -Force $out }

Write-Host "== WidgetTea $version" -ForegroundColor Cyan
Write-Host "   Update-Quelle: $(if ($Repository) { $Repository } else { '(keine – Updater aus)' })"

dotnet publish $csproj -c Release -r win-x64 --self-contained true `
    -p:UpdateRepository=$Repository -p:DebugType=none -o $publishDir
if ($LASTEXITCODE) { throw "dotnet publish fehlgeschlagen" }

& $makensis /V2 /INPUTCHARSET UTF8 "/DVERSION=$version" "/DSRCDIR=$publishDir" "/DOUTFILE=$setup" "/DHOMEPAGE=$Repository" `
    (Join-Path $root 'installer\WidgetTea.nsi')
if ($LASTEXITCODE) { throw "makensis fehlgeschlagen" }

$hash = (Get-FileHash $setup -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -Path "$setup.sha256" -Value "$hash  $setupName" -Encoding ascii -NoNewline
Write-Host "   Setup:  $setup ($([math]::Round((Get-Item $setup).Length / 1MB, 1)) MB)"
Write-Host "   SHA256: $hash"

if (-not $Publish) { return }

# ---- Veröffentlichen (GitHub) ----
if ($Repository -notmatch '^https://github\.com/([^/]+/[^/]+)$') { throw "-Publish erwartet ein GitHub-Repository, nicht $Repository" }
$slug = $Matches[1]
if (git -C $root status --porcelain) { throw "Arbeitsverzeichnis nicht sauber – erst committen." }
$tag = "v$version"
if (git -C $root tag --list $tag) { throw "Tag $tag existiert bereits – <Version> in WidgetTea.csproj erhöhen." }

git -C $root tag -a $tag -m "WidgetTea $version"
git -C $root push origin $tag
if ($LASTEXITCODE) { throw "Push des Tags fehlgeschlagen" }

gh release create $tag $setup "$setup.sha256" --repo $slug --title "WidgetTea $version" --generate-notes --verify-tag
if ($LASTEXITCODE) { throw "gh release create fehlgeschlagen" }
Write-Host "== Release veröffentlicht: https://github.com/$slug/releases/tag/$tag" -ForegroundColor Green
