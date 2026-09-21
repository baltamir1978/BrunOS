#!/bin/bash
# Descarga JetBrains Mono e IBM Plex Sans desde sus releases de GitHub y deja
# en BrunOS/Resources/Fonts/ sólo los cortes que usa la app, más sus OFL.
#
# Las fuentes SÍ se versionan en el repositorio: la OFL lo permite y así el
# proyecto compila recién clonado. Este script sólo hace falta para actualizarlas.
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="BrunOS/Resources/Fonts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

JETBRAINS_TAG="v2.304"
PLEX_TAG="@ibm/plex-sans@1.1.0"

mkdir -p "$DEST"

echo "==> JetBrains Mono $JETBRAINS_TAG"
gh release download "$JETBRAINS_TAG" -R JetBrains/JetBrainsMono \
  -p "JetBrainsMono-*.zip" -D "$TMP" --clobber
unzip -q -o "$TMP"/JetBrainsMono-*.zip -d "$TMP/jb"
for cut in Regular Bold Italic BoldItalic; do
  find "$TMP/jb" -name "JetBrainsMono-$cut.ttf" -exec cp {} "$DEST/" \;
done
find "$TMP/jb" -iname "OFL.txt" -exec cp {} "$DEST/OFL-JetBrainsMono.txt" \;

echo "==> IBM Plex Sans $PLEX_TAG"
gh release download "$PLEX_TAG" -R IBM/plex \
  -p "ibm-plex-sans.zip" -D "$TMP" --clobber
unzip -q -o "$TMP/ibm-plex-sans.zip" -d "$TMP/plex"
for cut in Regular Medium SemiBold; do
  find "$TMP/plex" -name "IBMPlexSans-$cut.ttf" -print -quit | \
    xargs -I{} cp {} "$DEST/"
done
find "$TMP/plex" \( -iname "LICENSE.txt" -o -iname "OFL.txt" \) -print -quit | \
  xargs -I{} cp {} "$DEST/OFL-IBMPlexSans.txt"

echo
echo "==> En $DEST:"
ls -1 "$DEST"
