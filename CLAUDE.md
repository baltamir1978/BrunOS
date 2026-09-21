# BrunOS — contexto del repositorio

App iOS personal (**no va a la App Store**, se instala por TestFlight como tester interno) que
convierte un iPhone 17 en un escritorio sobre un monitor externo, manejado con ratón y teclado
Bluetooth. No duplica la pantalla del teléfono: dibuja en la externa a resolución nativa.

Tres funciones: **terminal SSH** por Tailscale, **navegador** con pestañas y bloqueo de anuncios,
y **gestor de ficheros** (iPhone, iCloud Drive, USB y SFTP). El iPhone queda de mando: trackpad de
emergencia, teclado, dictado y ajustes.

---

## ⚠ ESTADO ACTUAL — LEER PRIMERO

**Fase 1 escrita entera. Compila y arranca, pero con un agujero grande de verificación.**

Verificado ejecutando, no leyendo:

- `xcodebuild ... build` termina en **BUILD SUCCEEDED**, con **un solo warning**, que está
  documentado y acorralado a propósito (ver `installBrunOSTap`).
- La app **arranca en el simulador de iPhone 17 con iOS 27.0** y se queda viva. La interfaz del
  teléfono sale entera: marca, estado de periféricos, trackpad y los cuatro botones con Liquid
  Glass, con "Traer ventana" deshabilitado porque es de la Fase 3.
- **Las fuentes cargan de verdad** (comprobado en captura: si el nombre PostScript estuviera mal
  se vería San Francisco).
- **`registerSceneAccessory(_:)` no falla en iOS 27**: el log emite "Accesorio de escena externa
  registrado" al arrancar.

**Lo que NO está verificado, que es casi todo lo importante de la Fase 1.** Bruno decidió
expresamente seguir a ciegas hasta el final y probarlo todo junto en el iPhone; conviene no
confundir "está escrito" con "funciona":

- **Nada de la pantalla externa se ha ejecutado nunca.** `xcrun simctl` **no sabe** simular una
  pantalla externa y el Device Hub de Xcode 27 es interfaz gráfica. Así que `ExternalSceneDelegate`,
  `ExternalDisplayManager.attach`, todo `DesktopViewController` y el mosaico entero son **código
  que no ha corrido ni una vez**.
- **El espacio lógico es la apuesta más arriesgada.** El lienzo se escala con un `CGAffineTransform`
  para que los puntos lógicos acaben en píxeles nativos. Si el factor está mal, se verá todo
  borroso o cortado. Es lo primero que hay que mirar con un monitor delante.
- **El ratón no se ha probado con hardware.** Ni `GCMouse` ni el puntero indirecto. En particular,
  no se sabe **cuál de las dos fuentes acaba entregando eventos de verdad en un iPhone**, que era
  justo la duda que motivó tener dos.
- **El dictado no se ha ejecutado.** La primera vez descarga el modelo de idioma y puede tardar.
- Los atajos, los divisores arrastrables y el teclado en pantalla: escritos, sin pulsar.

## Cómo se compila

```bash
./Tools/build.sh                  # xcodegen + xcodebuild al simulador
./Tools/fetch-fonts.sh            # sólo para actualizar las fuentes
./Tools/make-icon.sh              # regenera el PNG del AppIcon desde el SVG
```

**El `.xcodeproj` no se versiona**: lo regenera XcodeGen desde `project.yml`. Nunca editarlo a mano.

**`-skipPackagePluginValidation` es obligatorio.** SwiftTerm trae un build tool plugin
(`SwiftTermBuildInfoPlugin`) y Xcode se niega a ejecutarlo sin validar su huella. Desde la GUI sale
un diálogo de confianza; desde la línea de órdenes, sin ese flag, la compilación muere con
`Validate plug-in "SwiftTermBuildInfoPlugin" ... failed` y ningún otro dato. Por eso existe
`Tools/build.sh`.

**Hace falta el Metal Toolchain**, que no viene con Xcode 27: `xcodebuild -downloadComponent
MetalToolchain`. Sin él, SwiftTerm falla con `cannot execute tool 'metal'`.

---

## Decisiones cerradas (no cambiar sin preguntar a Bruno)

- Swift 6 en modo estricto (`SWIFT_STRICT_CONCURRENCY: complete`) desde el primer día.
- UIKit para la escena externa y el gestor de ventanas; SwiftUI para la interfaz del iPhone.
- **iOS 27 mínimo**, sólo iPhone, sólo vertical en el teléfono.
- Dependencias: **SwiftTerm** y **Citadel**, y ninguna más sin preguntar.
- Bundle id `com.bruno.brunos`. `DEVELOPMENT_TEAM` se deja vacío a propósito: el equipo de firma
  lo pone Bruno en Xcode y no entra en un repo público.
- Mosaico estilo i3 con 3 espacios de trabajo, sin ventanas flotantes en esta versión.
- Licencia **MIT** (decidida el 21-sep-2026).
- Repositorio **público**: nada de claves, tokens, hosts reales del tailnet ni IPs, tampoco en
  ejemplos o tests. Se usa `homelab` como nombre genérico. Revisar el diff antes de cada push.

---

## Lo que iOS 27 cambió, ya comprobado en el SDK instalado

Todo esto se verificó leyendo las cabeceras de `iPhoneOS27.0.sdk`, no de memoria.

- **La escena externa ya no se declara en el manifiesto.** `windowExternalDisplayNonInteractive`
  no se ofrece sola. El contenido externo lo registra el view controller raíz del iPhone con
  `registerSceneAccessory(_:)`. Encapsulado en `ExternalDisplayManager`.
  - El accesorio se crea con `UISceneAccessory.externalNonInteractive(sceneConfiguration:)`, que
    **exige un `UISceneConfiguration`**; no es una propiedad estática suelta como sugería el
    prompt inicial.
  - Ese `UISceneConfiguration` se crea con el inicializador **sin rol de sesión**,
    `UISceneConfiguration(name:)`, nuevo en iOS 27. El rol lo decide el accesorio.
  - `registerSceneAccessory` devuelve un `UISceneAccessoryRegistration` que **hay que conservar**:
    da `isEnabled` y permite desregistrar. Su `isAvailable` sólo es observable dentro de
    `updateProperties()` y `layoutSubviews()`.
- **Ciclo de vida por escenas obligatorio** y **`UILaunchScreen` obligatoria** en `Info.plist`.
- **`canOpenURL` obsoleto exactamente en iOS 27.0**: abrir la URL y gestionar el fallo.
- **`UIScreen.displayLink(withTarget:selector:)` obsoleto en iOS 27.** Esto **corrige el prompt
  inicial**, que pedía un `CADisplayLink` de la pantalla externa: hay que pedírselo a
  `UIWindowScene`, no a `UIScreen`. Ya aplicado en `PointerController.attach(to:)`.
- `UIScreen.main` ya estaba obsoleto desde iOS 26; se usa `view.window.windowScene.screen`.
- **`overscanCompensation` sigue vivo** y se pone a `.none`, como pedía el prompt.
- **WebKit (Safari 27), todo confirmado presente**:
  - `WKContentWorldConfiguration` con `allowAccessingClosedShadowRoots`.
  - `WKJSHandle`. Aparece además **`WKDOMNodeSnapshot`**, que el prompt no mencionaba y puede
    servir para el hover del navegador (Fase 3).
  - `webView(_:willSubmitForm:submissionHandler:)` en `WKNavigationDelegate`.
- **GameController sin cambios en iOS 27**: `GCMouse` sigue como desde iOS 14
  (`mouseMovedHandler`, `scroll`, tres botones y los auxiliares).

---

## Trampas encontradas

- **Los nombres PostScript de IBM Plex Sans están abreviados dentro del TTF**: el Regular es
  `IBMPlexSans` a secas, el Medium es `IBMPlexSans-Medm` y el SemiBold `IBMPlexSans-SmBld`. Pedir
  `"IBMPlexSans-Medium"` devuelve `nil` y UIKit cae en San Francisco **sin avisar de nada**. Los
  nombres buenos están en `Design/Tokens.swift`; si hace falta verificarlos otra vez, se leen de la
  tabla `name` del TTF, no del nombre del fichero.
- **El SVG del icono rotula "B_" con JetBrains Mono**, que no está instalada en el sistema.
  `Tools/make-icon.sh` levanta un `fontconfig` temporal apuntando a las fuentes del propio
  repositorio, así que el icono sale idéntico en cualquier Mac sin instalar nada.
- **`OSLog` a nivel `.info` no aparece en `log stream` por defecto.** Hay que pasar
  `--level debug` o parece que el código no se ha ejecutado. Costó un susto con el registro del
  accesorio de escena.
- **Las notificaciones de `GCMouse` se llaman distinto en Swift.** La cabecera declara
  `GCMouseDidConnectNotification` como `NSString *const`, pero Swift lo reexpone renombrado como
  `Notification.Name.GCMouseDidConnect`, **sin el sufijo "Notification"**. Escribirlo como en el
  header no compila, y envolverlo en `Notification.Name(...)` tampoco.
- **`Notification` no es `Sendable`.** En un observador de `NotificationCenter` no se puede sacar
  el `note` hacia `MainActor.assumeIsolated`: Swift 6 lo rechaza por riesgo de carrera. Se coge el
  dato de otro sitio (`GCMouse.current`) y listo.
- **`deinit` no puede tocar un `Timer`.** Un `deinit` corriente no está aislado a ningún actor y
  Swift 6 no deja ni leer una propiedad no `Sendable`. La salida es `isolated deinit`, de
  Swift 6.2. Está en `TopBar`.
- **`Equatable` sintetizado sólo funciona en el fichero que declara el tipo.** Conformar desde
  otro fichero obliga a escribir el `==` a mano; es más limpio declararlo en su sitio.

## Una obsolescencia de iOS 27 que no tiene salida

`AVAudioNode.installTap(onBus:bufferSize:format:block:)` quedó obsoleta en iOS 27 en favor de
`installTapOnBus:bufferSize:format:error:block:`. **Esa sustituta no se puede llamar desde Swift**
en el SDK 27: comprobado compilando contra `iphoneos27.0`, pasarle `error:` da *"extra arguments at
positions #4, #5"*. Y desambiguar por tipo tampoco vale, porque `throws` no cuenta para la
resolución de sobrecargas: las dos se importan con el mismo nombre y el mismo tipo.

Por eso `DictationController` usa la obsoleta a través de `installBrunOSTap`, un envoltorio cuyo
único propósito es que **el aviso salga en un sitio y no en cada llamada**. Es el único warning del
proyecto. No se marca `@available(deprecated:)` en el envoltorio: eso propagaría el aviso a quien
llame, justo lo contrario de lo que se busca.

## Cadena de suministro: mirar antes de la Fase 2

**Citadel 0.12.1 no usa el `swift-nio-ssh` de Apple.** Arrastra
`github.com/Wellz26/swift-nio-ssh` (0 estrellas), un fork de `Joannis/swift-nio-ssh`, que a su vez
forkea el de Apple. O sea: **toda la criptografía SSH de BrunOS pasa por el fork personal de un
tercero**, y en esta app por ahí van a ir contraseñas de servidores.

Comprobado, y por eso no se bloqueó la Fase 0:

- Wellz26 es colaborador real de Citadel; el cambio entró en el repositorio de arriba en abril de
  2026 con el mensaje "use Wellz26 nio-ssh fork for Mac Catalyst compatibility".
- El tag 0.3.7 del fork son merges legítimos del upstream de Apple.
- Aun así el fork va **7 commits por detrás** de `apple/swift-nio-ssh`.

Citadel **0.11.0 y anteriores** usan el fork de Joannis, el autor de Citadel. Si Bruno prefiere esa
cadena, se fija `exactVersion` o `upToNextMinor: 0.11.0` en `project.yml`. **Decisión pendiente,
para tomarla al empezar la Fase 2.**

---

## Estructura

```
BrunOS/
  App/         AppDelegate, PhoneSceneDelegate, ExternalSceneDelegate, Info.plist generado
  Display/     ExternalDisplayManager, DisplayProfile (escala, overscan, perfiles por pantalla)
  Input/       (Fase 1) PointerController, KeyboardRouter, atajos
  Desktop/     Pane (protocolo), DesktopViewController; (Fase 1) TilingLayout, Workspace, TopBar
  Terminal/    (Fase 2) TerminalPane, SSHSession, HostStore
  Browser/     (Fase 3) BrowserPane, TabModel, ContentBlocker, ClickInjector.js
  Files/       (Fase 4) FilesPane, LocalProvider, SFTPProvider, Bookmarks
  Phone/       PhoneRootViewController (UIKit, registra el accesorio) + vistas SwiftUI
  Design/      Tokens: colores, tipografías, métricas
  Resources/   Fonts (versionadas, OFL), Blocklists (generadas, NO versionadas), Assets
```

`PhoneRootViewController` es UIKit **a propósito**: `registerSceneAccessory(_:)` es un método de
`UIViewController`. La interfaz de dentro sí es SwiftUI, embebida con `UIHostingController`.

---

## Siguiente paso

**Fase 2: terminal SSH.** Antes de empezar hay **dos cosas que decidir con Bruno**:

1. Lo de Citadel y el fork de `swift-nio-ssh` de la sección anterior.
2. Si merece la pena seguir acumulando fases sin haber visto nunca la pantalla externa. La Fase 1
   entera descansa sobre código que no ha corrido; meterle encima un terminal multiplica lo que
   habría que desenredar si el espacio lógico resulta estar mal planteado.

Queda pendiente de la Fase 1, y está anotado en el código:

- **El lanzador (Cmd+P)** está en la tabla de atajos pero todavía no abre nada: necesita hosts,
  URLs y ubicaciones, que llegan con las fases 2 a 4.
- Cmd+T, Cmd+W, Cmd+L, Cmd+R, Cmd+F y los de zoom se reconocen y se encaminan, pero el panel de
  relleno no hace nada con ellos. `perform(_:)` devuelve `false` en esos casos a propósito.
- El contador de anuncios bloqueados de la barra superior se pasa como `nil` hasta la Fase 3.
