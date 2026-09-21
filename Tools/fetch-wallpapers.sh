#!/bin/bash
# Copia fondos de macOS de este Mac a BrunOS, reescalados para el monitor.
#
# LO COPIADO NO SE VERSIONA. Los fondos de macOS son de Apple: usarlos en tu
# propio iPhone es una cosa y redistribuirlos en un repositorio público es otra
# muy distinta. Por eso BrunOS/Resources/Wallpapers está en .gitignore, igual
# que las listas de bloqueo.
#
# BrunOS funciona sin esto: trae sus propios degradados, que se dibujan por
# código y van siempre.
set -euo pipefail

cd "$(dirname "$0")/.."
SOURCE="/System/Library/Desktop Pictures"
DEST="BrunOS/Resources/Wallpapers"

# Ancho al que se reescalan. Los originales son de 6016x6016 y ocupan decenas de
# MB cada uno; en un monitor de 4K no se nota la diferencia y el bundle no se
# dispara.
WIDTH="${1:-3840}"

[ -d "$SOURCE" ] || { echo "No hay fondos de macOS en $SOURCE" >&2; exit 1; }

mkdir -p "$DEST"
rm -f "$DEST"/*.heic

count=0
for file in "$SOURCE"/*.heic; do
  [ -f "$file" ] || continue
  name="$(basename "$file")"
  echo "==> $name"
  # -Z reescala por el lado mayor manteniendo la proporción.
  sips -s format heic -s formatOptions 70 -Z "$WIDTH" "$file" --out "$DEST/$name" >/dev/null 2>&1 \
    && count=$((count + 1))
done

echo
echo "==> $count fondos en $DEST"
du -sh "$DEST" 2>/dev/null
echo
echo "Los fondos dinámicos de macOS (.madesktop) no se copian: son descargas"
echo "bajo demanda y en este Mac puede que ni estén."
echo "Recuerda recompilar para que entren en el bundle."
