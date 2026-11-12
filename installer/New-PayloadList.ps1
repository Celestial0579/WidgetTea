<#
.SYNOPSIS
  Schreibt fuer makensis auf, welche Dateien das Setup installiert - als NSIS-Befehle, mit denen die
  Deinstallation genau diese Dateien wieder entfernt.

.DESCRIPTION
  WidgetTea.nsi ruft dieses Skript beim Uebersetzen selbst auf (!system) und bindet das Ergebnis im
  Abschnitt der Deinstallation ein. Von Hand ist kein Aufruf noetig.

  Die Liste entsteht aus dem Ordner, den auch "File /r" einpackt. Kommt im Programm eine Datei dazu,
  kennt die Deinstallation sie damit von selbst.

  Bewusst ohne Umlaute geschrieben: makensis startet Windows PowerShell 5.1, und die liest Skripte
  ohne BOM nicht als UTF-8.

.PARAMETER Source
  Der Ordner mit den Programmdateien (SRCDIR von WidgetTea.nsi, Ausgabe von dotnet publish).

.PARAMETER Out
  Die zu schreibende Datei mit den NSIS-Befehlen.
#>
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Out
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\')
$lines = New-Object System.Collections.Generic.List[string]

# In NSIS leitet $ eine Variable ein, ein $ im Dateinamen muss deshalb verdoppelt werden.
function ConvertTo-NsisPath([string]$FullName) {
    $FullName.Substring($root.Length + 1).Replace('$', '$$')
}

Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName | ForEach-Object {
    $lines.Add('Delete "$INSTDIR\' + (ConvertTo-NsisPath $_.FullName) + '"')
}

# Unterordner danach, die tiefsten zuerst. RMDir ohne /r entfernt einen Ordner nur, wenn er leer ist -
# liegt dort etwas Fremdes, bleibt er stehen.
Get-ChildItem -LiteralPath $root -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
    $lines.Add('RMDir "$INSTDIR\' + (ConvertTo-NsisPath $_.FullName) + '"')
}

if ($lines.Count -eq 0) { throw "Keine Dateien in $root - SRCDIR stimmt nicht." }

[System.IO.File]::WriteAllLines($Out, $lines, (New-Object System.Text.UTF8Encoding $false))
