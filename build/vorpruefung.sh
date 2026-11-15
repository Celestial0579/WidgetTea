#!/usr/bin/env bash
# vorpruefung.sh – prüft vor einem Push, was sich ohne Windows prüfen lässt (Issue 39).
#
#   build/vorpruefung.sh
#
# 1. App und Tests bauen, Warnungen als Fehler (-warnaserror), mit EnableWindowsTargeting.
# 2. Alle PowerShell-Skripte des Repos parsen (pwsh).
# 3. Das Setup übersetzen, wenn makensis da ist (Warnungen als Fehler); das Ergebnis wird verworfen.
#
# Was hier NICHT geprüft wird und nur auf Windows geht: die Tests ausführen (sie brauchen die Windows Desktop Runtime),
# das Setup ausführen und alles, was die Installer- und Selbst-Update-Prüfungen tun. Dafür bleibt die CI bzw. die
# Test-VM. Das hier übersetzte Setup ist nicht das ausgelieferte: Das baut build\release.ps1 unter Windows.
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
	# dotnet test bis zum Start des Testhosts: Fehler im Aufbau (etwa ein Testrunner, den das SDK nicht mehr
	# unterstützt) fallen so schon hier auf. Die Tests selbst laufen nur unter Windows; dass der Start an der
	# fehlenden Windows Desktop Runtime scheitert, ist hier erwartet.
	if log=$("$DOTNET" test --project tests/WidgetTea.Tests/WidgetTea.Tests.csproj -c Release -p:EnableWindowsTargeting=true 2>&1); then
		gut "dotnet test (Tests liefen)"
	elif grep -q 'Microsoft.WindowsDesktop.App' <<<"$log" && ! grep -qE ' error |: error ' <<<"$log"; then
		gut "dotnet test bis zum Start des Testhosts (die Tests selbst brauchen Windows)"
	else
		schlecht "dotnet test"
		grep -E 'error|Fehler' <<<"$log" | sed 's/^/       /' | sort -u | head -20
	fi
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
	trap 'rm -f "$parser"; rm -rf "${arbeit:-}"' EXIT
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

schritt "Setup übersetzen (NSIS)"
# MAKENSIS: Pfad zu makensis (Vorgabe: im Suchpfad). Ohne Root lässt es sich aus dem Ubuntu-Archiv entpacken:
#   apt-get download nsis nsis-common && for d in *.deb; do dpkg-deb -x "$d" root; done
#   MAKENSIS=$PWD/root/usr/bin/makensis NSISDIR=$PWD/root/usr/share/nsis build/vorpruefung.sh
MAKENSIS=${MAKENSIS:-$(command -v makensis || true)}
if [[ -z $MAKENSIS ]]; then
	hinweis "makensis nicht vorhanden; das Setup prüft erst die CI (siehe Kopf dieses Skripts)."
elif [[ -z $DOTNET || -z $PWSH ]]; then
	schlecht "zum Übersetzen fehlen dotnet oder pwsh"
else
	arbeit=$(mktemp -d -p "$PWD" .vorpruefung-XXXXXX)
	trap 'rm -f "${parser:-}"; rm -rf "$arbeit"' EXIT
	# WidgetTea.nsi ruft beim Übersetzen powershell.exe auf (New-PayloadList.ps1); hier übernimmt das pwsh.
	mkdir -p "$arbeit/bin"
	printf '#!/bin/sh\nexec "%s" "$@"\n' "$PWSH" >"$arbeit/bin/powershell.exe"
	chmod +x "$arbeit/bin/powershell.exe"
	version=$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' WidgetTea.csproj | head -1)
	if ! log=$("$DOTNET" publish WidgetTea.csproj -c Release -r win-x64 --self-contained false -p:EnableWindowsTargeting=true \
		-p:UpdateRepository=https://github.com/Celestial0579/WidgetTea -p:DebugType=none -o "$arbeit/publish" -nologo -v q 2>&1); then
		schlecht "dotnet publish"
		sed 's/^/       /' <<<"$log" | head -20
	elif log=$(cd installer && PATH="$arbeit/bin:$PATH" "$MAKENSIS" -V2 -WX -INPUTCHARSET UTF8 "-DVERSION=$version" \
		"-DSRCDIR=$arbeit/publish" "-DOUTFILE=$arbeit/WidgetTea-$version-pruefung.exe" -DHOMEPAGE=https://github.com/Celestial0579/WidgetTea \
		WidgetTea.nsi 2>&1); then
		gut "WidgetTea.nsi übersetzt, Warnungen als Fehler (Setup $version, nur zur Prüfung, wird verworfen)"
	else
		schlecht "WidgetTea.nsi"
		sed 's/^/       /' <<<"$log" | tail -20
	fi
	"$DOTNET" build-server shutdown >/dev/null 2>&1 || true
fi

echo
if ((fehler)); then
	echo "Vorprüfung: FEHLGESCHLAGEN – so nicht pushen."
	exit 1
fi
echo "Vorprüfung bestanden. Nicht geprüft: Tests ausführen, Setup ausführen, Installer- und Selbst-Update-Prüfungen (CI/VM)."
