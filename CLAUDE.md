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

- `xcodebuild ... build` termina en **BUILD SUCCEEDED**, **sin un solo warning** en código propio.
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

## Fase 2 — Terminal SSH

**Escrita y compilando. Ninguna conexión SSH se ha llegado a hacer.** No hay forma de probarla sin
un servidor, así que todo `SSHSession` y `TerminalTab` es código sin ejecutar.

Lo que hay:

- `SSHHost` + `HostStore`: perfiles en JSON en Application Support. **Los secretos no entran ahí**,
  van al Keychain con `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: no se sincronizan con iCloud
  y no se leen con el teléfono bloqueado.
- `TailscaleAuthentication`: el método SSH `none`. **Citadel no lo expone** —sus constructores
  llegan hasta `passwordBased` y las claves— pero sí expone `SSHAuthenticationMethod.custom(_:)`,
  que acepta un delegado propio. Con eso basta y **no hizo falta bajar a SwiftNIO a pelo**, que era
  el plan B del prompt.
- `SSHSession`: conexión, PTY, `window-change` al redimensionar, keepalive de 30 s y comando
  inicial. La reconexión es a mano, con Intro, desde el propio terminal.
- `TerminalPane` + `TerminalTab` + `TerminalTabBar`: SwiftTerm con 10.000 líneas de scrollback
  (las de serie son 500), traducción de teclas a secuencias de terminal, y pestañas por sesión.
- `TailscaleMonitor`: busca una interfaz `utun` con dirección de `100.64.0.0/10` o
  `fd7a:115c:a1e0::/48`. **Es un aviso y nunca bloquea**: no hay forma de preguntarle a Tailscale
  por su estado y la deducción puede fallar.
- `HostsView`: alta, edición y borrado de máquinas desde el iPhone.

Trampas de esta fase:

- **Ni Citadel ni NIO están migrados a la concurrencia estricta de Swift 6.** Hacen falta
  importaciones `@preconcurrency`. Y `TTYStdinWriter` no es `Sendable`, así que **no puede salir de
  la closure de `withPTY`**: `SSHSession` le manda órdenes por un `AsyncStream` y el writer se
  queda dentro, que es lo que hace que compile sin trampas.
- `TerminalViewDelegate` de SwiftTerm no está declarado `@MainActor` aunque siempre se llame desde
  la interfaz: la conformidad se marca `@preconcurrency`.
### SSH sin Tailscale, y el agujero de keyboard-interactive

**SSH funciona sin Tailscale**: con el método «Contraseña» se conecta a cualquier máquina
alcanzable desde la red del iPhone. Tailscale sólo aporta llegar a máquinas no expuestas y entrar
sin contraseña. El aviso de «Tailscale no parece activo» **sólo sale si hay algún host configurado
con ese método**, para no dar la lata a quien no lo use.

Pero hay una limitación seria, comprobada en la librería y **no arreglable desde BrunOS**:

**NIOSSH no implementa `keyboard-interactive`.** `NIOSSHAvailableUserAuthenticationMethods` sólo
contempla `publicKey`, `password` y `hostBased`, y la cadena "keyboard-interactive" no aparece en
ningún fichero de la librería. Importa porque hay servidores OpenSSH configurados con
`KbdInteractiveAuthentication yes` y `PasswordAuthentication no`, y **contra ésos la contraseña no
entra**. Las salidas son dos: usar clave pública, que Citadel sí admite (`ed25519`, `p256`, `rsa`;
quedaron fuera de esta versión por decisión del prompt, pero el diseño está preparado), o parchear
NIOSSH.

### Lo que queda fuera de la Fase 2, y por qué

- **Claves ed25519**: aplazadas a propósito, primero por el prompt y luego por Bruno. Citadel las
  admite (`ed25519`, `p256`, `p384`, `p521`, `rsa`), así que es añadir un caso a
  `SSHHost.Authentication` y guardar la clave en el Keychain.
- **`keyboard-interactive`**: **no es posible con NIOSSH**, ver arriba.
- **Banner de autenticación del servidor** (`SSH_MSG_USERAUTH_BANNER`): NIOSSH sólo lo contempla
  **del lado servidor**, en `SSHServerConfiguration.banner`. Un cliente no tiene forma de leerlo.
  El MOTD de después del login sí sale, porque llega por stdout como cualquier otra salida.
- **Cmd+clic sobre una URL abre Safari**, no el navegador de BrunOS, que todavía no existe. Cuando
  esté la Fase 3 hay que encaminarlo ahí, con Safari como alternativa.

### Claves de host (known_hosts)

**Ya está hecho**, en `KnownHosts.swift`. El cifrado de SSH impide que nadie escuche por el camino,
pero no dice **con quién** se está hablando: eso lo dice la clave del servidor. Sin comprobarla,
cualquiera que se meta en medio se presenta como tu máquina y le entregas la contraseña.

Se sigue el modelo de OpenSSH, **confianza en el primer uso**: la primera vez se guarda la huella
y a partir de ahí tiene que coincidir. Si cambia, **la conexión se corta** y se avisa en
Ajustes › SSH › Claves conocidas, donde Bruno decide. No es infalible —si el primer encuentro ya
estuviera interceptado, se guardaría la clave del atacante— pero es lo que hace `ssh` de siempre.

La huella es **SHA-256 en base64 sin el `=` final**, que es el formato que enseña OpenSSH, para
poder cotejarla a ojo contra `ssh-keyscan`.

`SSHHostKeyValidator.custom(_:)` de Citadel es público, así que no hizo falta rodearlo. El
validador es `Sendable` y sin estado mutable a propósito: NIO lo llama desde su event loop, no
desde el actor principal.

## Fondo del escritorio y dock

**El fondo del iPhone no se puede leer.** No hay API pública, comprobado en el SDK de iOS 27: iOS
no se lo enseña a las apps y es una decisión de privacidad, no un descuido. Así que BrunOS trae
los suyos.

- **Degradados propios**, dibujados por código en `Wallpaper.swift`. No pesan, no se pixelan a
  ninguna resolución y **van siempre**, también en un clon recién hecho. No son degradados planos:
  llevan un resplandor radial encima, que es lo que da el aire de los fondos de Apple. El de serie
  es `goldenGate`, un atardecer cálido que hace juego con el ámbar de la marca.
- **Fondos de macOS**: los copia `Tools/fetch-wallpapers.sh` desde `/System/Library/Desktop
  Pictures` del propio Mac, reescalados. **No se versionan**: son de Apple. En macOS 27 sólo quedan
  13 estáticos en disco; el resto son `.madesktop`, descargas bajo demanda que puede que ni estén.
- Sobre las imágenes va **un velo oscuro al 35 %**: los fondos de macOS son luminosos y encima de
  un cielo claro se pierden el texto de la barra y los bordes de los paneles.
- Pendiente (Fase 4): elegir una imagen cualquiera desde el gestor de ficheros. El caso
  `Wallpaper.file(bookmark:)` ya está previsto, con marcador de seguridad porque en iOS una carpeta
  externa deja de ser accesible entre sesiones sin él.

**El dock** sustituye a las tres etiquetas de espacios de la barra superior. El motivo es de uso:
`1 web · 2 ssh · 3 files` en una esquina se lee como un rótulo de estado, no como algo pulsable, y
obligaba a subir el ratón hasta arriba del todo, que con el tope del puntero indirecto es el
movimiento más incómodo que hay.

## Fase 4 — notas antes de empezar

- **Interfaz por decidir**: Finder o Total Commander de dos paneles. Sin decidir.
- **Vista previa con la barra espaciadora**, como en macOS. **Es viable**: `QLPreviewController`
  existe en iOS y cubre PDF, imágenes, GIF animado, vídeo y Office. Lo que hay que comprobar es que
  se deje incrustar **dentro de un panel del escritorio** en vez de presentarse como modal, porque
  en la pantalla externa no hay presentaciones modales que valgan. Si no se dejara, la alternativa
  es un visor propio con `AVPlayerLayer` y `PDFKit`, que cubre casi todo salvo Office.

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
- Bundle id **`com.baltamir.brunos`**. El primero que se intentó, `com.bruno.brunos`, **ya estaba
  registrado por otra cuenta**: los App ID son únicos en todo Apple. Una vez subida una build a
  App Store Connect ya no se puede cambiar.
- **La firma y el bundle id viven en `Local.xcconfig`**, que no se versiona, con
  `Local.xcconfig.example` de plantilla. Así el Team ID no entra en un repositorio público y, sobre
  todo, **sobrevive a `xcodegen generate`**, que rehace el `.xcodeproj` desde cero y se lleva por
  delante lo que se haya configurado en Xcode. `Tools/build.sh` lo crea desde el ejemplo si falta.
- **El subsistema de los logs se deriva de `Bundle.main.bundleIdentifier`** (ver `App/Log.swift`),
  no se escribe a mano: si no, al cambiar el bundle id los logs se irían a un nombre y el código
  los buscaría en otro.
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

## El único puente a Objective-C del proyecto

`AVAudioNode.installTap(onBus:bufferSize:format:block:)` quedó obsoleta en iOS 27 en favor de
`installTapOnBus:bufferSize:format:error:block:`. **Esa sustituta no se puede llamar desde Swift**
en el SDK 27: el `error:` va en medio de la firma, Swift lo convierte en `throws`, y `throws` no
cuenta para distinguir sobrecargas. Las dos acaban con el mismo nombre y el mismo tipo, y la
resolución se queda con la obsoleta. Comprobado compilando contra `iphoneos27.0`: pasarle `error:`
da *"extra arguments at positions #4, #5"*.

**Desde Objective-C no hay ambigüedad**, y eso sí está comprobado compilando un `.m` de prueba. De
ahí `BrunOS/Phone/BrunOSAudioTap.{h,m}` y el bridging header en `BrunOS/App/`, que es **lo único
de Objective-C que hay en BrunOS**. Reexpone el método con el `NSError **` al final, que es donde
Swift sí lo convierte en `throws`.

Se gana algo más que quitar un aviso: **el error deja de perderse**. Con la API vieja, un tap que
no se instalaba fallaba en silencio.

Si algún día Apple arregla la importación, se borran los dos ficheros y la línea
`SWIFT_OBJC_BRIDGING_HEADER` de `project.yml`, y se llama a la API directamente.

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
