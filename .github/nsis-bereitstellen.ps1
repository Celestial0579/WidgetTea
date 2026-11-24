# Stellt NSIS (makensis) für die CI bereit. Erst über Chocolatey mit bis zu drei Versuchen: Der Download scheitert
# gelegentlich, vor allem wenn mehrere Jobs gleichzeitig installieren. Fällt der Community-Feed ganz aus (am 24.11.2026
# rund 25 Minuten lang 503/504) oder fehlt Chocolatey, kommt NSIS über winget aus dem winget-Verzeichnis; winget prüft
# die Prüfsumme des Installers (#59). Auf dem ARM64-Runner ist NSIS meist schon installiert, dann passiert nichts.
$ErrorActionPreference = 'Continue'
$makensis = "${env:ProgramFiles(x86)}\NSIS\makensis.exe", "$env:ProgramFiles\NSIS\makensis.exe"
function Test-Nsis { [bool]($makensis | Where-Object { Test-Path $_ }) }

if (Get-Command choco -ErrorAction SilentlyContinue) {
    for ($try = 1; $try -le 3 -and -not (Test-Nsis); $try++) {
        if ($try -gt 1) { Start-Sleep -Seconds 20 }
        choco install nsis -y --no-progress
    }
}
if (-not (Test-Nsis)) {
    Write-Host 'Chocolatey lieferte NSIS nicht, jetzt über winget.'
    $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if (-not $winget) { $winget = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe' }
    for ($try = 1; $try -le 2 -and -not (Test-Nsis); $try++) {
        if ($try -gt 1) { Start-Sleep -Seconds 20 }
        & $winget install --id NSIS.NSIS --exact --source winget --silent --disable-interactivity `
            --accept-package-agreements --accept-source-agreements
    }
}
if (-not (Test-Nsis)) { throw 'NSIS ließ sich weder über Chocolatey noch über winget installieren' }
& ($makensis | Where-Object { Test-Path $_ } | Select-Object -First 1) /VERSION
exit 0
