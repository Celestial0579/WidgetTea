#!/usr/bin/env bash
# vorpruefung.sh – prüft vor einem Push, was sich ohne Windows prüfen lässt (Issue 39).
#
#   build/vorpruefung.sh
#
# 1. App und Tests bauen, Warnungen als Fehler (-warnaserror), mit EnableWindowsTargeting.
# 2. Alle PowerShell-Skripte des Repos parsen (pwsh).
# 3. NSIS: nur, wenn makensis da ist, und nur die Syntax des Setups (siehe unten).
#
# Was hier NICHT geprüft wird und nur auf Windows geht: die Tests ausführen (sie brauchen die Windows Desktop Runtime),
# das Setup wirklich bauen (WidgetTea.nsi ruft beim Übersetzen powershell.exe auf) und alles, was die
# Installer- und Selbst-Update-Prüfungen tun. Dafür bleibt die CI bzw. die Test-VM.
#
# Umgebung: DOTNET (Vorgabe: ~/.dotnet/dotnet, sonst dotnet im Suchpfad), PWSH (Vorgabe: pwsh, sonst /snap/bin/pwsh).
set -euo pipefail
cd "$(dirname "$0")/.."

fehler=0
schritt() { printf '\n== %s\n' "$*"; }
gut() { printf '   ok  %s\n' "$*"; }
schlecht() { printf '   !!  %s\n' "$*"; fehler=1; }
hinweis() { printf '   --  %s\n' "$*"; }

DOTNET=${DOTNET:-}
if [[ -z $DOTNET ]]; then
	if [[ -x $HOME/.dotnet/dotnet ]]; then DOTNET=$HOME/.dotnet/dotnet; else DOTNET=$(command -v dotnet || true); fi
fi
PWSH=${PWSH:-$(command -v pwsh || true)}
[[ -n $PWSH ]] || { [[ -x /snap/bin/pwsh ]] && PWSH=/snap/bin/pwsh; }

schritt "Bauen (Warnungen als Fehler)"
if [[ -z $DOTNET ]]; then
	schlecht "kein dotnet gefunden"
else
	hinweis "SDK: $("$DOTNET" --version)"
	for projekt in WidgetTea.csproj tests/WidgetTea.Tests/WidgetTea.Tests.csproj; do
		if log=$("$DOTNET" build "$projekt" -c Release -p:EnableWindowsTargeting=true -warnaserror -nologo -v q 2>&1); then
			gut "$projekt"
		else
			schlecht "$projekt"
			grep -E 'error|warning' <<<"$log" | sed 's/^/       /' | sort -u | head -30
		fi
	done
	# Der Build-Server hält sonst Arbeitsspeicher fest.
	"$DOTNET" build-server shutdown >/dev/null 2>&1 || true
fi

schritt "PowerShell-Skripte parsen"
if [[ -z $PWSH ]]; then
	schlecht "kein pwsh gefunden"
else
	mapfile -t skripte < <(git ls-files '*.ps1')
	# Über eine Skriptdatei: Was nach -Command steht, hängt pwsh an den Befehl an, statt es als $args zu übergeben.
	# Im Repo und nicht in /tmp, weil pwsh als Snap nicht überall lesen darf.
	parser=$(mktemp -p "$PWD" .vorpruefung-XXXXXX.ps1)
	trap 'rm -f "$parser"' EXIT
	cat >"$parser" <<'PS1'
$bad = 0
foreach ($f in $args) {
    $e = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$null, [ref]$e) | Out-Null
    foreach ($x in $e) { "{0}:{1}: {2}" -f $f, $x.Extent.StartLineNumber, $x.Message; $bad++ }
}
"GEPARST $($args.Count) FEHLER $bad"
PS1
	ausgabe=$("$PWSH" -NoProfile -NonInteractive -File "$parser" "${skripte[@]}" 2>&1) || true
	if grep -q 'FEHLER 0$' <<<"$ausgabe"; then
		gut "${#skripte[@]} Skripte ohne Fehler"
	else
		schlecht "Parse-Fehler:"
		sed 's/^/       /' <<<"$ausgabe"
	fi
fi

schritt "NSIS"
if command -v makensis >/dev/null; then
	hinweis "makensis gefunden, aber WidgetTea.nsi ruft beim Übersetzen powershell.exe auf (New-PayloadList.ps1); das geht nur auf Windows."
else
	hinweis "makensis nicht vorhanden; das Setup prüft erst die CI."
fi

echo
if ((fehler)); then
	echo "Vorprüfung: FEHLGESCHLAGEN – so nicht pushen."
	exit 1
fi
echo "Vorprüfung bestanden. Nicht geprüft: Tests ausführen, Setup bauen, Installer- und Selbst-Update-Prüfungen (CI/VM)."
