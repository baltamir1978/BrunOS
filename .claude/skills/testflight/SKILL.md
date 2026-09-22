---
name: testflight
description: Subir una build de BrunOS a App Store Connect / TestFlight y resolver los errores de distribución (DistributionAppRecordProviderError, App ID, cifrado).
---

## Distribución

**La primera build se subió a App Store Connect desde Xcode el 21-sep-2026** (Archive → Distribute
App), con `MARKETING_VERSION` 0.1.0 y build 1. Sólo TestFlight, como tester interno: los internos
no pasan por la revisión de Apple.

Lo que costó llegar ahí, por si se repite:

- `IDEDistribution.DistributionAppRecordProviderError error 0` al distribuir significa, casi
  siempre, que **la app no existe todavía en App Store Connect** con ese bundle id. No es un fallo
  de compilación: el archivo se generó bien y falla el paso de subirlo.
- El App ID hay que registrarlo antes en developer.apple.com como **Explicit**, no Wildcard, o App
  Store Connect no lo ofrece.
- `ITSAppUsesNonExemptEncryption = false` ya va en el `Info.plist`, así que App Store Connect **no
  pregunta por el cumplimiento de cifrado** en cada subida. El valor es `false` porque BrunOS sólo
  usa cifrado estándar del sistema —SSH por Citadel y HTTPS por WebKit— y eso entra en la exención;
  no implementa criptografía propia.
- Para instalar por **TestFlight no hace falta el Modo de desarrollador** del iPhone. Eso sólo es
  necesario para instalar y depurar directamente desde Xcode.

### `Tools/testflight.sh` (22-sep-2026)

Archiva, firma y sube sin abrir Xcode: `./Tools/testflight.sh`, o `--dry-run` para ver lo que
haría. **Probado: subió la 0.1.0 (2609221511) el 22-sep-2026.** Lo común a todas las apps (dónde
está la clave, cómo reutilizar el script) está en `/Users/bruno/Proyectos/CLAUDE.md`.

- **Credenciales fuera del repositorio**, que es público: `ASC_KEY_ID` y `ASC_ISSUER_ID` en el
  entorno o en `~/.config/appstoreconnect/testflight.env` (común a todas las apps); el `.p8` en
  `~/.appstoreconnect/private_keys/AuthKey_<ID>.p8`, que es donde lo deja Apple, o donde diga
  `ASC_KEY_PATH`. La clave se crea en App Store Connect › Users and Access › Integrations, con
  acceso de Administrador.
- **Número de build = fecha y hora** (`AAMMDDHHMM`, se pasa como `CURRENT_PROJECT_VERSION`):
  siempre crece y no hay contador que guardar. La versión visible sigue en `project.yml`.
- **Se niega a subir sin listas de bloqueo**: no se versionan, y una build sin ellas funciona
  pero no bloquea nada, que es fácil no notar hasta tenerla en el iPhone.
- Exporta con `destination: upload`, que sube directamente: sin altool ni Transporter.

### Límite diario de subidas

`error: exportArchive Upload limit reached. The upload limit for your application has been
reached. Please wait 1 day and try again.` Salió el 22-sep-2026 tras unas ocho subidas en el mismo
día. Apple no publica el número. **No hay nada que arreglar**: se espera al día siguiente. El
archivo compilado se queda en `build/testflight/`, pero el script vuelve a compilar al lanzarlo,
así que basta con repetir `./Tools/testflight.sh`.

Para no llegar a él: no subir en cada cambio suelto, sino agrupar arreglos seguidos en una build.
