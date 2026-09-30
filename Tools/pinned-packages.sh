# Las versiones exactas de las dependencias, fijadas en `Package.resolved` de la
# raíz, que se versiona (propuesta D1 del plan de optimización de la 0.2.0).
#
# Sin esto, cada Mac resolvía lo último que permite project.yml (SwiftTerm con
# `from:` admite cualquier 1.x), y una versión nueva entraba sin que nadie la
# revisara. Por Citadel pasan las contraseñas: lo que se compila tiene que ser
# lo revisado.
#
# Lo usan build.sh y testflight.sh (`source`). El .xcodeproj lo regenera
# XcodeGen y no se versiona, así que el fichero se copia dentro antes de
# compilar, y xcodebuild va con -disableAutomaticPackageResolution: si
# project.yml pide algo que no está en Package.resolved, falla en vez de
# resolver por su cuenta.
#
# Para subir una dependencia a propósito: borrar Package.resolved, compilar con
# build.sh (lo vuelve a crear), revisar el diff y subirlo.

RESOLVED_IN_PROJECT="BrunOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PACKAGE_FLAGS=()

use_pinned_packages() {
  if [ -f Package.resolved ]; then
    mkdir -p "$(dirname "$RESOLVED_IN_PROJECT")"
    cp Package.resolved "$RESOLVED_IN_PROJECT"
    PACKAGE_FLAGS=(-disableAutomaticPackageResolution)
  else
    echo "==> No hay Package.resolved en la raíz: se resuelven las dependencias y se guardará al terminar"
  fi
}

save_pinned_packages() {
  if [ ! -f Package.resolved ] && [ -f "$RESOLVED_IN_PROJECT" ]; then
    cp "$RESOLVED_IN_PROJECT" Package.resolved
    echo "==> Package.resolved guardado en la raíz: revisa las versiones y súbelo al repositorio"
  fi
}
