# BrunOS — contexto del repositorio

App iOS personal (**no va a la App Store**, se instala por TestFlight como tester interno) que
convierte un iPhone 17 en un escritorio sobre un monitor externo, manejado con ratón y teclado
Bluetooth. No duplica la pantalla del teléfono: dibuja en la externa a resolución nativa.

Cinco apps en el dock: **navegador** (pestañas, bloqueo de anuncios y de avisos de cookies),
**terminal SSH** (por Tailscale), **Ficheros** (iPhone, iCloud Drive, USB, SFTP y SMB), **Notas**
(con historial del portapapeles) y **Fotos** (visor de una carpeta). El iPhone queda de mando:
trackpad, teclado, dictado y atenuar.

---

## ⚠ Estado actual — leer primero (30-sep-2026)

**La 0.1.0 está cerrada** (etiqueta `v0.1.0`, build 2609300854): Bruno la probó entera en el
iPhone con el monitor y la dio por buena. Su historia, build a build, está en `git log`.
**Ahora es la 0.2.0** (`MARKETING_VERSION` en `project.yml`).

### Plan de la 0.2.0 (Bruno, 30-sep-2026)

1. **Supr** en todos los paneles. *Escrito.*
2. ~~Modo presentación~~: **descartado por Bruno**. Se le dieron cuatro opciones (PDF con el visor
   propio, PPTX/Keynote/Excel con WebKit, convertir a PDF por SSH con LibreOffice, usar
   Keynote/PowerPoint del iPhone) y no quiso ninguna. No volver a proponerlo.
3. **Exportar favoritos** al mismo HTML con el que se importan. *Escrito.*
4. **Velocidad y memoria**: revisado y propuesto (ver «Plan de optimización»). Bruno eligió
   **todos los A y C, y B3, B4 y D1**: *escritos*. B1 y B2, sin elegir.
5. **Ratón con `GCMouse` más natural**: aceleración, curva y rueda, sin cambiar la fuente.
   *Sin empezar.*
6. **El tiempo con varias ciudades**, alternando desde la barra. *Escrito.*
7. **Transparencia del dock y de la barra superior**, en Ajustes. *Escrito.*

### Visto bien por Bruno en la 2609301421 (30-sep-2026)

Supr en todos los paneles, exportar favoritos, el tiempo con varias ciudades (salvo el texto,
abajo), la barra sin ventanas y toda la optimización (A1–A3, B3, B4, C1). D1: `Package.resolved`
en el repositorio (Citadel 0.11.1, `swift-nio-ssh` 0.3.5 de Joannis, SwiftTerm 1.20.0, AMSMB2
4.0.3); `build.sh` y `testflight.sh` compilan sólo con esas versiones
(`-disableAutomaticPackageResolution`). Si `xcodebuild` protesta por la resolución, es que
`project.yml` pide algo que no está en `Package.resolved`.

### Pendiente de probar (0.2.0)

Lo que Bruno pidió al probar la 2609301421. Compila sin warnings y se vio en el simulador a
1,5× (escritorio montado en la pantalla del iPhone con un arnés provisional, no versionado).
**Subido en la 2609301513** (30-sep-2026, tarde). Quitar cada cosa de aquí al confirmarla.

- **Transparencia con deslizador** (Bruno lo pidió): de 0 a 100 %, dock y barra por separado
  (`SettingsRow.Control.slider`). Lo guardado con los cuatro niveles de antes se recoge. Ajustes
  se queda con el ratón mientras el botón sigue pulsado (`settingsCapture`), así que el
  deslizador sigue al cursor aunque se salga de la ventana.
- **La línea blanca bajo la barra** con mucha transparencia: el separador se transparenta ahora
  con la barra.
- **El texto del tiempo se veía fatal**: a 1,5× el desplegable y las etiquetas de la barra caían
  a medio píxel y, con el filtro `.nearest`, las letras salían dentadas. Ahora van a píxel
  entero (`pixelAlignCards`, también el calendario y el menú; `PixelSnappingStackView` en la
  barra).
- **El clic de AssistiveTouch en los bordes del iPhone** (Bruno: a veces pulsaba su menú): en
  modo mando se esconden la barra de estado y el indicador de inicio y se aplazan los gestos de
  los bordes; la explicación de «Mostrar siempre el menú» y un interruptor de prueba para
  bloquear el puntero, en Ajustes › Ratón y teclado › «El clic en el iPhone». Mirar qué dice
  «Estado del bloqueo» al activarlo.

### Ideas aparcadas

- **YouTube**: sólo saldría lanzando yt-dlp en una máquina del tailnet por SSH. HLS ya se baja.
- Navegación privada, zoom por sitio y buscadores propios: **descartados por Bruno** (24-sep).

---

## Cómo se cierra cada bloque de trabajo

Lo pidió Bruno (22-sep-2026): **cada bloque que compile sin errores termina en commit, `git push`
y README y memoria al día**, sin preguntar en cada paso. Antes del push, revisar el diff por si
se cuela algo sensible: el repositorio es público.

**La subida a TestFlight se avisa antes y se espera el visto bueno** (23-sep: «no subas más
compilaciones sin avisar para no bloquear»): cada subida gasta del límite diario de App Store
Connect. Skill `testflight` (`.claude/skills/testflight/`).

**Lo escrito sin probar va a «Pendiente de probar»** y se quita al confirmarlo. No confundir «está
escrito» con «funciona». Desde Linux no hay compilador: se escribe, se revisa el diff a mano (y
con tree-sitter para la sintaxis, que da falsos positivos ya conocidos en `HistoryWindow`,
`SettingsPages`, `TopBar`, `Workspace` y `FilesPane`) y se compila luego en el Mac.

## Reglas (romperlas ya ha costado un fallo)

- **Colores en la pantalla externa**: nunca `.cgColor` de un color dinámico, siempre
  `.desktopCGColor`. Lo que se asigne a una capa se reasigna en `applyTheme()` o con
  `setThemedBorder`.
- **Lo que se añada a `canvas` fuera de la maquetación, con `applyContentsScale` justo
  después** (o `matchCanvasDensity`).
- **Nada se dibuja en la vista que tiene la tarjeta como subvista**; dibuja la `CardView`, y
  quien dibuje desde su esquina, con `translateBy` (entrega coordenadas de la ventana).
- **Una ventana modal nueva entra en todas las listas** (ver `BrunOS/Desktop/CLAUDE.md`).
- **Lo que se escribe en un campo propio sale de `KeyEvent.typedText`**, nunca de
  `key.characters`.
- **Un cambio de título, pestaña o selección va por `notifyTitleChange()`**, no por
  `notifyChange()`, que recoloca todo el escritorio.
- **Nada de lo que cuelga de `AppServices.shared` puede mirar a `AppServices.shared` en su
  `init`**: pedir un `static let` mientras se inicializa bloquea Swift para siempre en
  `swift_once`, sin traza (la app dejó de arrancar así). Lo que lo necesite, en `start()`.
- **Ratón: manda `GCMouse`** (ver `BrunOS/Input/CLAUDE.md`). **AssistiveTouch: siempre
  `isActive` y `mouseDetected`**, nunca `isRunning` o `hasMouse` a pelo.
- **Todo lo que se ve tiene que poder pulsarse.**
- **Si cambia un atajo, cambiarlo también en `BrowserTab.helpHTML()`** (la ayuda de la página de
  inicio).
- **Cero warnings** en código propio.

## Dónde está el resto

Lo de cada parte vive junto a su código y se carga sólo al trabajar allí:

- `BrunOS/Desktop/CLAUDE.md`: ventanas, dock, barra superior (Tailscale, tiempo, calendario),
  modales, ajustes del monitor, densidad y colores, fondo.
- `BrunOS/Input/CLAUDE.md`: el ratón (`GCMouse` y AssistiveTouch) y el teclado.
- `BrunOS/Phone/CLAUDE.md`: el iPhone de mando con monitor, conectar y desconectar, el puente a
  Objective-C.
- `BrunOS/Browser/CLAUDE.md`: WebKit, el inyector de clics y teclas, descargas, bloqueadores,
  favoritos.
- `BrunOS/Terminal/CLAUDE.md`: SSH, Citadel, `known_hosts`, keyboard-interactive, el tema.
- `BrunOS/Files/CLAUDE.md`: orígenes de ficheros, SMB, marcadores de seguridad, vista previa, ZIP.
- `BrunOS/Notes/CLAUDE.md` y `BrunOS/Photos/CLAUDE.md`.

## Cómo se compila

```bash
./Tools/build.sh                  # xcodegen + xcodebuild al simulador
./Tools/fetch-fonts.sh            # sólo para actualizar las fuentes
./Tools/make-icon.sh              # regenera el PNG del AppIcon desde el SVG
./Tools/fetch-wallpapers.sh       # copia fondos de macOS (no se versionan)
```

- **El `.xcodeproj` no se versiona**: lo regenera XcodeGen desde `project.yml`. Nunca a mano.
- **`-skipPackagePluginValidation` es obligatorio** (el plugin de SwiftTerm; sin él muere con
  `Validate plug-in "SwiftTermBuildInfoPlugin" ... failed`). Por eso existe `Tools/build.sh`.
- **Hace falta el Metal Toolchain**: `xcodebuild -downloadComponent MetalToolchain`.
- El simulador **no simula pantalla externa**: lo del monitor sólo se prueba en el iPhone.

## Decisiones cerradas (no cambiar sin preguntar a Bruno)

- Swift 6 estricto (`SWIFT_STRICT_CONCURRENCY: complete`). UIKit para la escena externa y el
  gestor de ventanas; SwiftUI para la interfaz del iPhone. **iOS 27 mínimo**, sólo iPhone, sólo
  vertical en el teléfono.
- Dependencias: **SwiftTerm**, **Citadel** (fijado a la serie 0.11, ver «Cadena de suministro»)
  y **AMSMB2** (dinámica: **necesita `embed: true`** o la app no arranca en el iPhone;
  `testflight.sh` se niega a subir si falta un framework). Ninguna más sin preguntar.
- Bundle id **`com.baltamir.brunos`** (`com.bruno.brunos` era de otra cuenta; ya no se puede
  cambiar). **Firma y bundle id en `Local.xcconfig`**, que no se versiona (plantilla
  `Local.xcconfig.example`): sobrevive a `xcodegen generate` y el Team ID no entra en el repo.
- El subsistema de los logs sale de `Bundle.main.bundleIdentifier` (`App/Log.swift`).
- **Un solo escritorio**, ventanas flotantes por defecto y mosaico estilo i3. Sigue el modo
  claro/oscuro del iPhone por defecto.
- **Los avisos de cookies** se bajan de la rama `master` del repositorio de OhMyGuus («I Still
  Don't Care About Cookies») y corren en todas las páginas, en su propio mundo de contenido. Si
  alguien comprometiera ese repositorio, su código correría en todas las webs: **riesgo aceptado
  por Bruno** (24-sep-2026). Las listas de anuncios, en cambio, son reglas declarativas.
- Licencia **MIT**. Repositorio **público**: nada de claves, tokens, hosts reales del tailnet ni
  IPs, tampoco en ejemplos o tests (se usa `homelab`). Revisar el diff antes de cada push.

## Lo que iOS 27 cambió (comprobado en el SDK)

- **La escena externa ya no se declara en el manifiesto**: la registra el view controller raíz
  del iPhone con `registerSceneAccessory(_:)` (en `ExternalDisplayManager`), con
  `UISceneAccessory.externalNonInteractive(sceneConfiguration:)` y un `UISceneConfiguration(name:)`
  sin rol. El `UISceneAccessoryRegistration` hay que conservarlo; su `isAvailable` sólo es
  observable en `updateProperties()` y `layoutSubviews()`.
- Ciclo de vida por escenas y `UILaunchScreen` obligatorios. `canOpenURL` obsoleto: abrir la URL
  y gestionar el fallo.
- `UIScreen.displayLink` obsoleto: el `CADisplayLink` se pide a `UIWindowScene`. `UIScreen.main`
  también: `view.window.windowScene.screen`. `overscanCompensation` sigue, a `.none`.
- WebKit 27: `WKContentWorldConfiguration.allowAccessingClosedShadowRoots`, `WKJSHandle`,
  `WKDOMNodeSnapshot` y `webView(_:willSubmitForm:submissionHandler:)`, todos presentes.
- GameController sin cambios: `GCMouse` como desde iOS 14.

## Trampas encontradas

- **Nombres PostScript de IBM Plex Sans abreviados** en el TTF (`IBMPlexSans-Medm`,
  `IBMPlexSans-SmBld`): con el nombre largo UIKit cae en San Francisco sin avisar. Los buenos,
  en `Design/Tokens.swift`; se leen de la tabla `name` del TTF.
- `Tools/make-icon.sh` levanta un `fontconfig` temporal con JetBrains Mono del repositorio.
- **`OSLog` a nivel `.info` no sale en `log stream`** sin `--level debug`.
- `GCMouseDidConnectNotification` es `Notification.Name.GCMouseDidConnect` en Swift.
- **`Notification` no es `Sendable`**: en un observador no se saca el `note` hacia
  `MainActor.assumeIsolated`; el dato se coge de otro sitio.
- **`deinit` no puede tocar un `Timer`**: `isolated deinit` (Swift 6.2), como en `TopBar`.
- **`Equatable` sintetizado sólo funciona en el fichero que declara el tipo.**
- **`isFocused` choca con la de `UIView`** (en Notas es `hasFocus`).
- **Sin Modo de desarrollador no hay informes de fallo** (`devicectl` no monta la imagen): los
  fallos se buscan leyendo el código y en `EventLog`.

## Cadena de suministro: Citadel fijado a la 0.11

**Citadel 0.12.x no usa el `swift-nio-ssh` de Apple ni el de su autor**, sino
`github.com/Wellz26/swift-nio-ssh` (un fork de terceros; comprobado otra vez el 30-sep-2026 en la
0.12.1 y en `main`). Por esa capa pasa toda la criptografía SSH, contraseñas incluidas. La serie
0.11 (`minorVersion: 0.11.0`, resuelve a la 0.11.1) tira del fork de **Joannis, el autor de
Citadel** (0.3.x): la cadena más corta y con un responsable identificable. **Antes de subir de
versión, mirar de qué fork tira la nueva en su `Package.swift`.**

**`Package.resolved` se versiona** (desde el 30-sep-2026, propuesta D1) y fija las versiones
exactas: `Tools/pinned-packages.sh` lo copia dentro del `.xcodeproj` y compila sin resolver por su
cuenta. Para subir una dependencia a propósito: borrarlo, compilar con `build.sh` (lo vuelve a
crear), revisar el diff y subirlo.

## Estructura

- `App/`: arranque, `AppServices` (el singleton con todos los servicios), escenas, `EventLog`.
- `Desktop/`: el escritorio de la pantalla externa (`DesktopViewController`, ventanas, dock,
  barra, modales, ajustes, tiempo).
- `Display/`: perfil de pantalla, `ExternalDisplayManager`, modo claro/oscuro, fondos.
- `Input/`: ratón, cursor (`PointerController`), teclado (`KeyboardRouter`, `Shortcuts`),
  AssistiveTouch.
- `Browser/`, `Terminal/`, `Files/`, `Notes/`, `Photos/`: una app cada una.
- `Phone/`: la interfaz del iPhone (SwiftUI), el trackpad y el modo mando.
- `Design/Tokens.swift`: colores, fuentes y medidas.

---

## Plan de optimización (punto 4, 30-sep-2026)

Revisión del código, sin medir aún en el iPhone (para eso, Ajustes › Rendimiento). Ordenado por lo
que se nota en el uso diario. **Bruno eligió todos los A y C, y B3, B4 y D1: escritos, sin
compilar.** B1 y B2 siguen propuestos.

Cómo quedó lo escrito:

- **A1**: `placeFloatingWindows` coloca sólo las ventanas que se arrastran y sus sombras; si el
  dock tiene que esconderse o asomar, o alguna no está en el lienzo, maqueta entero. Al soltar,
  el `notifyChange()` de siempre. `TopBar.update` y `Dock.update` no tocan nada si no ha cambiado
  (`statusKey`, `lastState`, `setText`).
- **A2**: en Ficheros y Fotos la lista va en una vista propia (`FilesContentView`,
  `PhotosContentView`) dentro de `contentClip`, un 30 % más alta por arriba y por abajo que lo
  que se ve: la rueda sólo la mueve (`placeContent`), y se repinta al salirse de lo pintado. Hover
  y selección repintan sólo esos elementos (`invalidateItems`, `invalidateTiles`). Dibuja con las
  coordenadas del panel (`drawContent` traslada el contexto) y sólo lo que cae en `drawRange`.
  `setNeedsDisplay()` del panel está sobrescrito para repintarlo todo, así que las llamadas de
  siempre siguen valiendo. En Ficheros, el resalte de soltar y la copia van en `overlay`.
- **A3**: `deliverPointer` junta los movimientos y los entrega una vez por fotograma desde el
  `CADisplayLink` del cursor (`PointerController.onFrame`); antes de un clic o de la rueda se
  entrega el pendiente (`flushQueuedMove`).
- **A4**: índice de fotos por ruta (`mediaIndex`), `DateFormatter` del calendario cacheado.
- **C1**: `ModalWindow` y `openModals`, la única lista de modales. Encajar y la barra superior,
  en `DesktopViewController+Snap.swift` y `+TopBar.swift` (el estado sigue en el principal).
- **C2**: fuera `PlaceholderPane` y el contador de bloqueados; `PaneKind` en su fichero.
- **B3**: `TerminalTheme.scrollback`, 5.000 por defecto, en Terminal › Apariencia › Historial.
- **B4**: `FilesPane.thumbnails` es un `NSCache` de 40 MB; al guardarla, la ruta sale de
  pendientes para poder pedirla otra vez si se suelta.
- **D1**: `Package.resolved` versionado y `Tools/pinned-packages.sh` (ver «Cadena de suministro»).

### A. Respuesta de la interfaz

- **A1. Arrastrar y redimensionar ventanas rehace el escritorio entero en cada movimiento.**
  `handleWindowDrag` llama a `layoutWithoutAnimation()` → `layoutCanvas()` con cada evento del
  ratón: recorre todo el lienzo con `applyContentsScale`, vuelve a apilar todas las flotantes
  (`addSubview` + `bringSubviewToFront`), y actualiza dock y barra superior (que reasigna textos e
  imágenes y fuerza Auto Layout en la barra). Propuesta: un camino rápido para el arrastre (sólo el
  marco de esa ventana y su sombra), `applyContentsScale` sólo a las vistas nuevas, y barra y dock
  que no toquen nada si no ha cambiado. Ganancia grande, riesgo bajo.
- **A2. Ficheros y Fotos repintan el panel entero** en `draw(_:)` (CPU, a la densidad del monitor)
  con cada paso de rueda y cada cambio de hover o selección. Propuesta rápida:
  `setNeedsDisplay(in:)` para hover y selección. Propuesta de fondo: celdas como capas
  reutilizables y el desplazamiento moviendo `bounds` (lo hace la GPU). Ganancia grande en carpetas
  con muchas fotos; la de fondo es un cambio mediano.
- **A3. Cada evento del ratón pasa entero por `deliverPointer`** (hit-test, forma del cursor, hover
  del dock, hover del navegador por JavaScript). `GCMouse` puede dar más eventos que fotogramas
  con ratones de 500–1000 Hz. Propuesta: juntar los movimientos y procesar uno por fotograma en el
  `CADisplayLink` del cursor; clics y rueda, al momento. Antes, mirar en Diagnóstico cuántos
  eventos por segundo llegan.
- **A4. Menores**: `media.firstIndex(of:)` dentro del bucle de miniaturas de Fotos (cuadrático
  con miles de fotos); `DateFormatter` nuevo en cada dibujado del calendario y en cada pronóstico;
  `applyContentsScale` dos veces seguidas en `presentWeather`.

### B. Memoria

- **B1. Nadie atiende los avisos de memoria** (`didReceiveMemoryWarningNotification`), y la app ya
  la ha cerrado iOS por memoria. Propuesta: al recibirlo, dormir las pestañas que no se ven y
  vaciar las cachés de miniaturas, iconos y fondos.
- **B2. Pestañas despiertas**: 5 entre todos los navegadores, cada una con su proceso de WebKit.
  Propuesta: 3, o dormir según `os_proc_available_memory`.
- **B3. Scrollback del terminal de 10.000 líneas por pestaña**: SwiftTerm guarda cada celda con
  sus atributos, y con muchas columnas son decenas de MB por pestaña llena. Propuesta: 5.000, o un
  ajuste en Terminal › Apariencia.
- **B4. Las miniaturas de Ficheros van en un diccionario sin límite** (se vacía al cambiar de
  carpeta). Propuesta: `NSCache` con límite, como Fotos.

### C. Código

- **C1. `DesktopViewController` tiene 2.668 líneas** y las ventanas modales están repetidas en seis
  listas a mano (puntero, cursor, `performOverModal`, `deliverKey`, marcos de `layoutCanvas`,
  orden de `arrangeFloating`): olvidar una es un fallo seguro. Propuesta: un protocolo
  `ModalWindow` y una sola lista ordenada; después, sacar a ficheros propios el arrastre de
  ventanas, el encaje y lo de la barra superior.
- **C2. Código muerto**: `PlaceholderPane` (unas 110 líneas, no se usa) vive en un fichero que
  además aloja `PaneKind`: mover `PaneKind` a su fichero y borrar el resto. El contador de
  bloqueados (`blockedLabel`, `blockedCount`) se quitó pero su código sigue, siempre a `nil`.

### D. Dependencias

- **D1. `Package.resolved` no se versiona**, y SwiftTerm va con `from: 1.2.0`: admite cualquier
  1.x (hoy la última es la 1.20.0). Una versión nueva de SwiftTerm entraría sin que nadie la
  revise. Propuesta: versionar `Package.resolved` (no lleva nada sensible) y fijar SwiftTerm con
  `upToNextMinor` a la versión que ya se usa. Así lo que se compila es siempre lo revisado.
- **D2.** Citadel 0.11.1 y AMSMB2 4.0.3 son las últimas de su serie. Nada que hacer.
