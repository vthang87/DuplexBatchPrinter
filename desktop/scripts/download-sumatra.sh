#!/usr/bin/env bash
# Downloads SumatraPDF portable for Windows silent printing.
# License: GPLv3 — see resources/windows/THIRD_PARTY.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/src-tauri/resources/windows"
VERSION="${SUMATRA_VERSION:-3.5.2}"
URL="https://www.sumatrapdfreader.org/dl/rel/${VERSION}/SumatraPDF-${VERSION}-64.zip"
TMP="$(mktemp -d)"

mkdir -p "$DEST"
echo "Downloading SumatraPDF ${VERSION}…"
curl -L --fail "$URL" -o "$TMP/sumatra.zip"
unzip -o "$TMP/sumatra.zip" -d "$TMP"
find "$TMP" -name 'SumatraPDF*.exe' -print -exec cp {} "$DEST/SumatraPDF.exe" \;
rm -rf "$TMP"

if [[ ! -f "$DEST/SumatraPDF.exe" ]]; then
  echo "Failed to extract SumatraPDF.exe" >&2
  exit 1
fi

echo "Installed $DEST/SumatraPDF.exe"
