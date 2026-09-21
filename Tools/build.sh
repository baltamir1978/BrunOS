#!/bin/bash
# Regenera el proyecto con XcodeGen y compila para el simulador.
#
# Existe por un motivo concreto: SwiftTerm trae un build tool plugin
# (SwiftTermBuildInfoPlugin) y Xcode se niega a ejecutarlo sin validar su huella.
# En la GUI se resuelve con un diálogo de confianza; desde la línea de órdenes
# hace falta -skipPackagePluginValidation, y si no se pasa la compilación falla
# con "Validate plug-in ... failed" sin más explicación.
set -euo pipefail

cd "$(dirname "$0")/.."

DESTINATION="${1:-generic/platform=iOS Simulator}"

# La firma vive fuera del repositorio. En un clon recién hecho no existe, y sin
# él xcodegen no encuentra el xcconfig que referencia project.yml.
if [ ! -f Local.xcconfig ]; then
  echo "==> Local.xcconfig no existe; creándolo desde el ejemplo"
  cp Local.xcconfig.example Local.xcconfig
  echo "    Rellena DEVELOPMENT_TEAM para poder firmar en un dispositivo."
fi

echo "==> xcodegen"
xcodegen generate

echo "==> xcodebuild ($DESTINATION)"
xcodebuild -scheme BrunOS \
  -destination "$DESTINATION" \
  -skipPackagePluginValidation \
  build
