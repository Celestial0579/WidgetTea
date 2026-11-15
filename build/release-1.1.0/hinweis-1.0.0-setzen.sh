#!/usr/bin/env bash
# Setzt den Sicherheitshinweis vor den Release-Text von 1.0.0. Der bisherige Text bleibt darunter stehen.
#   ./hinweis-1.0.0-setzen.sh            zeigt nur, wie der Text danach aussaehe
#   ./hinweis-1.0.0-setzen.sh --setzen   aendert den Release-Text auf GitHub
# Erst ausfuehren, wenn 1.1.0 und das Advisory veroeffentlicht sind: Der Hinweis verlinkt beides.
set -euo pipefail
REPO=${WT_REPO:-Celestial0579/WidgetTea}
GH=${WT_GH:-gh}
HIER=$(cd "$(dirname "$0")" && pwd)
ALT=$("$GH" release view v1.0.0 --repo "$REPO" --json body --jq .body)
if [[ $ALT == *"GHSA-mgf2-2f98-ff87"* ]]; then echo "Der Hinweis steht schon im Release-Text von 1.0.0. Nichts zu tun."; exit 0; fi
NEU=$(mktemp)
trap 'rm -f "$NEU"' EXIT
{ cat "$HIER/hinweis-1.0.0.md"; printf '%s\n' "$ALT"; } >"$NEU"
echo "--- Release-Text von 1.0.0 danach:"
cat "$NEU"
echo "---"
if [[ ${1:-} == --setzen ]]; then
	"$GH" release edit v1.0.0 --repo "$REPO" --notes-file "$NEU"
	echo "Gesetzt."
else
	echo "Nichts geaendert. Zum Setzen: $0 --setzen"
fi
