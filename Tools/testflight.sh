#!/bin/bash
# Compila, firma y sube BrunOS a App Store Connect para TestFlight.
#
#   ./Tools/testflight.sh             # archiva y sube
#   ./Tools/testflight.sh --dry-run   # dice lo que haría, sin compilar ni subir
#
# CREDENCIALES: NUNCA EN EL REPOSITORIO, QUE ES PÚBLICO.
#
# Hace falta una clave de la API de App Store Connect (Users and Access ›
# Integrations › App Store Connect API, con acceso de Administrador). Se leen de
# variables de entorno o, si existe, de ~/.config/appstoreconnect/testflight.env,
# que está fuera del repositorio y es común a todas las apps de la cuenta:
#
#   ASC_KEY_ID=ABC123DEFG
#   ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
#   ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_ABC123DEFG.p8   # opcional
#
# Si no se da ASC_KEY_PATH, se busca el .p8 donde lo deja Apple por defecto:
# ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8.
#
# NÚMERO DE BUILD: la fecha y la hora, AAMMDDHHMM. Siempre crece, que es lo
# único que exige App Store Connect, y no hay contador que guardar ni que se
# desincronice entre máquinas. La versión visible (MARKETING_VERSION) sigue
# siendo la de project.yml: ésa se cambia a mano cuando toca.
set -euo pipefail

cd "$(dirname "$0")/.."

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

say() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

CONFIG="$HOME/.config/appstoreconnect/testflight.env"
if [ -f "$CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

[ -n "${ASC_KEY_ID:-}" ] || fail "Falta ASC_KEY_ID. Ponlo en $CONFIG o en el entorno."
[ -n "${ASC_ISSUER_ID:-}" ] || fail "Falta ASC_ISSUER_ID. Ponlo en $CONFIG o en el entorno."
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
KEY_PATH="${KEY_PATH/#\~/$HOME}"
[ -f "$KEY_PATH" ] || fail "No encuentro la clave .p8 en $KEY_PATH."

[ -f Local.xcconfig ] || fail "Falta Local.xcconfig con el DEVELOPMENT_TEAM. Cópialo de Local.xcconfig.example."
grep -Eq '^DEVELOPMENT_TEAM *= *[A-Z0-9]+' Local.xcconfig \
  || fail "DEVELOPMENT_TEAM está vacío en Local.xcconfig."

# Las listas de bloqueo no se versionan: sin ellas la app funciona, pero sin
# bloquear nada, y es fácil no darse cuenta hasta tener la build en el iPhone.
if ! ls BrunOS/Resources/Blocklists/blocklist-*.json >/dev/null 2>&1; then
  fail "No hay listas de bloqueo. Ejecuta ./Tools/fetch-blocklists.sh antes de subir."
fi
if ! ls BrunOS/Resources/Wallpapers/* >/dev/null 2>&1; then
  say "Aviso: no hay fondos de macOS (Tools/fetch-wallpapers.sh). Se sube sólo con los degradados."
fi

BUILD_NUMBER="$(date +%y%m%d%H%M)"
VERSION="$(grep -E '^ *MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')"
ARCHIVE="build/testflight/BrunOS-$VERSION-$BUILD_NUMBER.xcarchive"
EXPORT_DIR="build/testflight/export-$BUILD_NUMBER"
OPTIONS="$(mktemp -t brunos-export).plist"
trap 'rm -f "$OPTIONS"' EXIT

AUTH=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

# Exportar con destino «upload» sube directamente a App Store Connect: no
# hace falta altool ni Transporter.
cat > "$OPTIONS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>upload</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
PLIST

say "BrunOS $VERSION ($BUILD_NUMBER)"
say "Clave de la API: $ASC_KEY_ID"

if [ "$DRY_RUN" = 1 ]; then
  say "Simulación: no se compila ni se sube nada."
  echo "  xcodegen generate"
  echo "  xcodebuild archive -scheme BrunOS -destination generic/platform=iOS \\"
  echo "    -archivePath $ARCHIVE CURRENT_PROJECT_VERSION=$BUILD_NUMBER -skipPackagePluginValidation <clave>"
  echo "  xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath $EXPORT_DIR <clave>"
  exit 0
fi

say "xcodegen"
xcodegen generate

say "Archivando"
xcodebuild archive \
  -scheme BrunOS \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  -skipPackagePluginValidation \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${AUTH[@]}"

say "Firmando y subiendo a App Store Connect"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$OPTIONS" \
  "${AUTH[@]}"

say "Subida $VERSION ($BUILD_NUMBER). App Store Connect tarda unos minutos en procesarla;"
say "después aparece en TestFlight para los testers internos, sin revisión de Apple."
