#!/bin/bash
# Rasteriza brunos-icon.svg a 1024x1024 y lo deja en el AppIcon del asset catalog.
#
# El SVG rotula "B_" con JetBrains Mono, que no está instalada en el sistema.
# En vez de instalarla, se levanta un fontconfig temporal que apunta a las
# fuentes del propio repositorio: así el icono sale idéntico en cualquier Mac.
set -euo pipefail

cd "$(dirname "$0")/.."
SVG="brunos-icon.svg"
FONTS="$PWD/BrunOS/Resources/Fonts"
DEST="BrunOS/Resources/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$FONTS/JetBrainsMono-Bold.ttf" ] || {
  echo "Faltan las fuentes. Ejecuta antes Tools/fetch-fonts.sh" >&2; exit 1; }

cat > "$TMP/fonts.conf" <<EOF
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>$FONTS</dir>
  <cachedir>$TMP/cache</cachedir>
</fontconfig>
EOF

mkdir -p "$DEST"
FONTCONFIG_FILE="$TMP/fonts.conf" \
  rsvg-convert -w 1024 -h 1024 -o "$DEST/AppIcon-1024.png" "$SVG"

echo "==> $DEST/AppIcon-1024.png"
sips -g pixelWidth -g pixelHeight -g hasAlpha "$DEST/AppIcon-1024.png" | tail -3
