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

`Tools/testflight.sh`, con la clave de la API de App Store Connect y el incremento automático de
build, sigue **sin escribirse**: está previsto para el final de la Fase 4. Hasta entonces, las
subidas van a mano desde Xcode.
