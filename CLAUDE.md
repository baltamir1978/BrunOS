# BrunOS — contexto del repositorio

App iOS personal (**no va a la App Store**, se instala por TestFlight como tester interno) que
convierte un iPhone 17 en un escritorio sobre un monitor externo, manejado con ratón y teclado
Bluetooth. No duplica la pantalla del teléfono: dibuja en la externa a resolución nativa.

Tres funciones: **terminal SSH** por Tailscale, **navegador** con pestañas y bloqueo de anuncios,
y **gestor de ficheros** (iPhone, iCloud Drive, USB y SFTP). El iPhone queda de mando: trackpad de
emergencia, teclado, dictado y ajustes.

---

## ⚠ ESTADO ACTUAL — LEER PRIMERO (22-sep-2026)

**Las cuatro fases están escritas. Terminal y navegador se usan ya en el iPhone con monitor; el
gestor de ficheros está a medias.**

Visto funcionando en el dispositivo, con monitor delante:

- **La escena externa arranca y dibuja**: escritorio, barra, dock y cursor. Los fallos que han ido
  saliendo (cursor invisible, webs enormes, clics perdidos por AssistiveTouch, cierres por
  memoria) se encontraron usándolo, y están contados en sus secciones.
- **El ratón llega a través de AssistiveTouch**: el clic izquierdo se convierte en un toque sobre
  el iPhone. De ahí que el teléfono se quede en negro con monitor puesto (`RemoteModeView`).
- **SSH conecta de verdad** contra una máquina de Bruno.
- El bloqueador de anuncios compila sus 3 listas (114.213 reglas).

Compila con **BUILD SUCCEEDED y sin un solo warning** en código propio, y arranca en el simulador
de iPhone 17 con iOS 27.0. El simulador **no sabe** simular una pantalla externa, así que lo del
monitor sólo se puede comprobar en el iPhone.

**Escrito y sin probar en el dispositivo.** Bruno prefiere acumular y probarlo todo junto;
conviene no confundir "está escrito" con "funciona":

- **Lo del 22-sep**: el modo claro en el monitor y su cambio en caliente, los fondos claros, el
  terminal claro, las ventanas que salían vacías, los ajustes nuevos, la lista de conexiones del
  terminal, la pantalla completa, el menú del botón derecho y las descargas del navegador, las
  vistas de iconos y el cierre de los ajustes del iPhone al conectar. Intro, Retroceso y las
  descargas **sí** se comprobaron en un `WKWebView` de macOS, pero no en el iPhone.
- Terminal: tmux y vim con ratón, selección con arrastre, `known_hosts` ante una clave que cambie
  y la reconexión tras una caída real.
- Navegador: clics sintéticos, pestañas y descargas contra webs de verdad.
- Ficheros: SFTP, carpetas externas (iCloud, USB) y copiar entre orígenes.
- El dictado (la primera vez descarga el modelo de idioma y puede tardar), los atajos, los
  divisores arrastrables y el teclado en pantalla.
- **Si el espacio lógico sale nítido** a todas las escalas: el lienzo se escala con un
  `CGAffineTransform` y, si el factor estuviera mal, se vería borroso o cortado.

## Cómo se cierra cada bloque de trabajo

Lo pidió Bruno el 22-sep-2026: **cada bloque que compile sin errores termina en commit, `git push`,
subida a TestFlight (`./Tools/testflight.sh`) y README y memoria al día**, sin preguntar en cada
paso. Antes del push, revisar el diff por si se cuela algo sensible: el repositorio es público.

Última build subida: **0.1.0 (2609221525)**, 22-sep-2026, con el dock estilo macOS.

## Dónde está el resto

Lo de cada parte vive junto a su código y se carga sólo al trabajar allí:

- `BrunOS/Terminal/CLAUDE.md`: SSH, Citadel, `known_hosts`, keyboard-interactive, el tema del terminal.
- `BrunOS/Browser/CLAUDE.md`: WebKit, el inyector de clics y teclas, descargas, el bloqueador y
  sus restricciones.
- `BrunOS/Files/CLAUDE.md`: orígenes de ficheros, marcadores de seguridad, la vista previa propia.
- `BrunOS/Phone/CLAUDE.md`: el único puente a Objective-C (`installTap`).
- Skill `testflight` (`.claude/skills/testflight/`): subir builds y los errores de distribución.

---

## Escritorio y pantalla externa

### El cursor invisible, y por qué afectaba a todo el escritorio

`UIColor.cgColor` resuelve un color dinámico **con el modo que esté activo en el instante de la
llamada**, y ahí se queda: no se entera de los cambios. Las capas del escritorio se crean muy
pronto, antes de que exista el view controller que fuerza `.dark`, así que con el iPhone en modo
claro salían con los colores claros. El cursor, que usa `text`, acababa siendo **casi negro sobre
el fondo oscuro del escritorio**: invisible.

Afectaba a cualquier `CALayer` de la pantalla externa, no sólo al cursor. La solución es
`UIColor.desktopCGColor` (en `Tokens.swift`), que resuelve con el modo del escritorio. **Regla: en
la pantalla externa, nunca `.cgColor` de un color dinámico; siempre `.desktopCGColor`.** El cursor
es la excepción: va siempre resuelto en oscuro (claro con borde negro), que se ve en los dos modos.

### Claro u oscuro (22-sep-2026)

El escritorio iba **siempre oscuro**, y Bruno se hartó: con el iPhone en claro, el monitor seguía
en negro. Ahora `DesktopTheme` (en `Display/`) lo decide: **por defecto sigue al iPhone**, y en
Ajustes se puede fijar en claro u oscuro. El modo del teléfono lo apunta
`PhoneRootViewController` con `registerForTraitChanges`: la escena externa no lo hereda de forma
fiable. El terminal sigue oscuro en los dos modos.

**Lo que obliga a cualquier vista nueva**: un `CGColor` no se entera del cambio. Lo que se pinte
en `draw(_:)` se repinta solo (el escritorio hace `setNeedsDisplay` en todo el árbol), pero **lo
que se asigne a una capa** —`borderColor`, `backgroundColor` de un `CALayer`— hay que volver a
asignarlo en `DesktopViewController.applyTheme()`. Los paneles lo hacen ya por `setFocused`, y
**para un borde fijo basta `view.setThemedBorder(color)`**, que apunta el color dinámico y lo
vuelve a resolver solo en cada cambio de modo.

### Ajustes: los globales en el dock, los de cada panel en su barra (22-sep-2026)

Bruno pidió que cada cosa esté donde se usa: la rueda del dock abre lo que afecta a todo el
escritorio (modo, fondo con miniaturas, pantalla, ratón, acerca de) y cada panel tiene su rueda
(navegador: buscador, zoom, bloqueo, descargas; terminal: máquinas, apariencia, claves conocidas;
ficheros: vista y ubicaciones). La ventana (`SettingsWindow`) imita Ajustes del Sistema: secciones
a la izquierda y grupos con interruptores, segmentados y botones. El contenido se describe en
`SettingsPages` y se vuelve a pedir tras cada cambio. **Las zonas pulsables se apuntan al
dibujar**, en el mismo cálculo, para que lo que se ve y lo que responde no se desalineen.

La primera versión era una lista de filas que cambiaban de valor al pulsarlas: Bruno la llamó
«un horror» y no dejaba cambiar casi nada. Las explicaciones de cada ajuste van en la nota de
debajo de su grupo.

### Pantalla completa y los botones de ventana

Ctrl+Cmd+F, o desde Ajustes › Pantalla: se esconden dock y barra y los paneles se llevan todo. El
dock asoma al llevar el cursor al borde de abajo, y la barra al de arriba.

Cada panel lleva las **tres bolitas de macOS** (`WindowControls`), con lo que Bruno decidió
pensando ya en las ventanas flotantes: **rojo cierra, amarillo al dock, verde maximiza** (a
pantalla completa). Lo minimizado sale del mosaico pero sigue vivo —la sesión SSH no se corta—.
Cmd+Intro sigue maximizando dentro del mosaico.

**El dock es el de macOS** (lo pidió Bruno): un icono por app, siempre a color, con un **punto
debajo si está abierta** —ámbar la que se ve, gris las demás—, y lo minimizado cuenta como
abierto. Al pulsar un icono vuelven sus paneles minimizados y, si estaba cerrada, **se abre un
panel nuevo**, como al lanzar una app. Antes los espacios vacíos salían en gris, lo minimizado
tenía un icono aparte duplicado, y con la app cerrada no había forma de volver a abrirla.

### El lanzador (Cmd+P)

Busca en todo a la vez: máquinas SSH, ubicaciones de Ficheros, marcadores, historial del navegador
y acciones (panel nuevo, pantalla completa, ajustes). Lo escrito se ofrece además como dirección o
como búsqueda web con el buscador elegido. El historial (`BrowserHistory`) guarda una entrada por
dirección, como mucho 500, en Application Support; los marcadores se ponen con el botón derecho.

### Buscar (Cmd+F)

Una barra propia (`FindBar`), la misma en los tres paneles: en el navegador busca con
`WKWebView.find` (resalta y lleva al resultado; el total se cuenta aparte en el texto de la página,
porque WebKit sólo dice si ha encontrado algo), en el terminal con la búsqueda de SwiftTerm, que da
«2 de 14» e incluye el historial, y en Ficheros filtra la carpeta por nombre. Intro al siguiente,
Mayús+Intro al anterior, Esc cierra.

### Ventanas flotantes (22-sep-2026)

Un panel está **o en el mosaico o flotando**, nunca en los dos: `Workspace.floating` guarda el
marco de cada flotante y `floatingOrder` el apilamiento; al flotar sale de `TilingLayout`, y al
volver entra junto al primer panel del mosaico. Las flotantes van encima del mosaico, con sombra
en una vista aparte (los paneles recortan su contenido y se la comerían), y **por debajo de las
barras y de las ventanas modales**, que se vuelven a traer delante en cada maquetación.

- **Soltar del mosaico**: arrastrando la parte vacía de la barra del panel (`Pane.isDragArea`).
  Hay un umbral de 8 puntos para que un clic en la barra no lo saque sin querer.
- **Redimensionar**: 6 puntos a cada lado del borde de una flotante. Se miran antes que el
  contenido del panel, que si no se los comería.
- **Doble clic en la barra** o Cmd+Mayús+Espacio (el Mod+Mayús+Espacio de i3): flotante ↔ mosaico.
- Verde en una flotante: se lleva la pantalla entera; Cmd+Intro: el área del mosaico. Las dos
  recuerdan el marco anterior (`zoomRestore`).
- Un arrastre en curso manda sobre el dock y la barra superior: si no, al pasar por encima se
  quedaban el movimiento.
- Ajustes › General › Ventanas: si los paneles nuevos salen flotando o en mosaico.

**Sin probar en el iPhone.** No hay cursor de redimensionar: el cursor sigue siendo la flecha.

### El ratón se atascaba en el borde del iPhone: ahora va en absoluto

Con AssistiveTouch, el ratón llega como **puntero indirecto**: iOS mueve su propio puntero por la
pantalla del iPhone y la app ve su posición. Antes se restaban posiciones para sacar
desplazamientos y se sumaban al cursor de BrunOS, con aceleración encima. Los dos cursores se
descuadraban y, cuando el del sistema topaba con el borde del teléfono, **el del monitor se
quedaba trabado a media pantalla**. Ajustar la sensibilidad sólo lo retrasaba.

Ahora `IndirectPointerSource` manda la **posición normalizada** (0…1) y el cursor del monitor va
exactamente ahí: el borde del iPhone es el borde del monitor, a la vez. La velocidad la pone iOS
(Accesibilidad › Control del puntero › Velocidad de seguimiento); la sensibilidad y la aceleración
de BrunOS quedan para el trackpad táctil y para `GCMouse`, que sigue siendo relativo.

**Sin probar en el iPhone.** Si la posición que da el puntero indirecto no cubre la pantalla
entera (por ejemplo, si iOS la limita al área segura), el cursor no llegaría a los bordes del
monitor: es lo primero que hay que mirar.

### Atenuar

Baja el brillo del iPhone al mínimo (`ScreenDimmer`) y pone un velo que **no recibe toques**: el
trackpad sigue funcionando. Antes era un negro opaco que se comía los toques. El brillo es un
ajuste del sistema, así que se devuelve al salir de la app.

### Al conectar el monitor, el iPhone vuelve a su pantalla de mando

Si los ajustes del iPhone estaban abiertos al conectar, el clic que AssistiveTouch convierte en
toque caía sobre ellos y **el ratón parecía muerto** en el monitor. Ahora se cierra lo que haya
presentado (salvo el selector de carpetas, que se pide desde el monitor) y se recupera el primer
respondedor para el teclado.

**AssistiveTouch salía «inactivo» estando activo**: `isAssistiveTouchRunning` no es fiable con
AssistiveTouch puesto sólo para el puntero. Si llegan eventos del ratón, se da por activo.

### Los ajustes salían vacíos: dibujar debajo de la tarjeta

Síntoma: en los ajustes del monitor sólo se veían la marca y el aspa. **Las filas se dibujaban
en el `draw(_:)` de la vista de fondo, y una vista dibuja su contenido debajo de sus subvistas**:
la tarjeta, opaca, lo tapaba todo. Pasaba igual en el menú contextual, el diálogo de texto y el
editor de máquinas. Ahora dibuja la propia tarjeta (`CardView`). **Regla: en una ventana, nada se
dibuja en la vista que tiene la tarjeta como subvista.**

### La app se cerraba al hacer varios clics

Síntoma: pulsar el dock o el navegador varias veces y la app al suelo. Dos causas, las dos en el
mismo sitio:

1. **`WallpaperStore.apply` se llamaba en cada pasada de layout del escritorio**, o sea en cada
   clic. Con un fondo de imagen, eso significaba **volver a decodificar un HEIC de 3840 px cada
   vez**. Unos cuantos clics y iOS mataba la app por memoria. Ahora se recuerda lo último pintado
   y la imagen decodificada se cachea.
2. **Recursión infinita si la imagen de fondo faltaba**: `apply` cambiaba `current`, eso disparaba
   la notificación de cambio, que provocaba otra pasada de layout, que volvía a llamar a `apply`.
   El cambio va ahora aplazado a la siguiente vuelta del bucle de ejecución.

Como red de seguridad, `layoutCanvas()` lleva un cerrojo de reentrada: varias cosas de dentro
avisan de que han cambiado y esos avisos vuelven ahí. **Sin el cerrojo, cualquier aviso mal puesto
se convierte en recursión y la app se cierra sin dejar rastro.**

Había además un bucle latente en el lanzador: `addPane(.terminal)` llamaba a
`openTerminalSession`, que con más de una máquina abría el lanzador, que al elegir llamaba a
`addPane`... De ahí el parámetro `autoStart`.

**Nota sobre diagnóstico**: sin el Modo de desarrollador activado en el iPhone no se pueden sacar
los informes de fallo (`devicectl` no puede montar la imagen de desarrollo). Estos dos se
encontraron leyendo el código.

### El iPhone se apaga cuando hay monitor, y por qué

**El diagnóstico lo dio Bruno**: el dock fallaba porque, con AssistiveTouch, el botón izquierdo no
llega a la app como botón — iOS lo convierte en un **toque en la pantalla del teléfono**. Si en ese
punto había un botón de la interfaz del iPhone, se pulsaba ése y el escritorio del monitor ni se
enteraba. Funcionaba o no según dónde hubiera quedado el puntero.

La única forma de que el clic llegue **siempre** al sitio correcto es que en el iPhone no haya nada
más que tocar. De ahí `RemoteModeView`: con pantalla externa conectada el teléfono queda en negro,
como superficie táctil y nada más, con un aviso que se va solo a los seis segundos y que **no
acepta toques**, porque si no sería otra cosa robándole el clic al trackpad.

**Consecuencia obligada: los ajustes se mudan al monitor** (`SettingsWindow`), y con ellos el alta
y la edición de máquinas SSH (`HostEditorWindow`). Si el iPhone está apagado, nada de esto puede
vivir allí.

El editor de máquinas lleva **campos de texto propios**, no `UITextField`: en la pantalla externa
no hay eventos del sistema ni first responder que valga, así que el teclado llega por el
`KeyboardRouter` y se reparte a mano entre los campos, con Tab para saltar de uno a otro. Es el
mismo mecanismo que la barra de direcciones del navegador.

La interfaz del iPhone sigue entera **sin monitor conectado**, que es cuando tiene sentido.

Los ajustes del monitor **no llevan deslizadores**: con un cursor propio, arrastrar uno es
incómodo, así que las filas van pasando por los valores útiles al pulsarlas.

### Todo lo que se ve tiene que poder pulsarse

Principio que pidió Bruno y que se aplicó a todo: el dock, la barra superior (la marca abre el
lanzador, la resolución lleva a los ajustes), las filas del lanzador, las pestañas y la barra de
direcciones del navegador. Un rótulo con pinta de botón que no responde es peor que no ponerlo.

Como en la pantalla externa no hay eventos del sistema, **cada vista expone un `hit(at:)`** que
resuelve por geometría qué hay bajo el cursor, y el escritorio pregunta.

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
- **Imagen propia**: botón derecho sobre una imagen en Ficheros › «Usar como fondo de escritorio».
  Se **copia** a Application Support (`Wallpaper.custom`), reducida a 3840 px. El marcador de
  seguridad que se había previsto (`Wallpaper.file`) no servía: con una foto del propio
  contenedor el permiso falla, y por SFTP no hay marcador posible.

**El dock** sustituye a las tres etiquetas de espacios de la barra superior. El motivo es de uso:
`1 web · 2 ssh · 3 files` en una esquina se lee como un rótulo de estado, no como algo pulsable, y
obligaba a subir el ratón hasta arriba del todo, que con el tope del puntero indirecto es el
movimiento más incómodo que hay.

## Pendientes


## El bloqueo de arranque del singleton

La app dejó de arrancar, sin mensaje: el log se cortaba y se quedaba colgada. Causa:
`FileService.init()` llamaba a `rebuild()`, que mira `AppServices.shared` para sacar las máquinas
SSH — y `FileService` se construye **dentro** de esa misma propiedad estática. **Pedir un `static
let` mientras se está inicializando deja a Swift bloqueado para siempre en `swift_once`**, sin
excepción ni traza. Los orígenes se montan ahora desde `AppServices.start()`.

**Regla**: nada de lo que cuelga de `AppServices.shared` puede mirar a `AppServices.shared` en su
`init`.

**Pendiente**: copiar carpetas enteras con progreso, y arrastrar entre ubicaciones.

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
- Dependencias: **SwiftTerm** y **Citadel**, y ninguna más sin preguntar. **Citadel fijado a la
  serie 0.11** (22-sep-2026), por el fork de `swift-nio-ssh` del que tira: ver "Cadena de
  suministro".
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
- El escritorio **sigue el modo claro/oscuro del iPhone** por defecto (22-sep-2026). Antes iba
  siempre oscuro y Bruno lo rechazó.
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

## Cadena de suministro: Citadel fijado a la 0.11

**Citadel 0.12.1 no usa el `swift-nio-ssh` de Apple.** Arrastra
`github.com/Wellz26/swift-nio-ssh` (0 estrellas), un fork de `Joannis/swift-nio-ssh`, que a su vez
forkea el de Apple. Por esa capa pasa toda la criptografía SSH de BrunOS, contraseñas incluidas.

No había indicios de nada malo —Wellz26 es colaborador real de Citadel, el cambio entró en abril
de 2026 "for Mac Catalyst compatibility" y el tag 0.3.7 del fork son merges legítimos del de
Apple—, pero el fork iba 7 commits por detrás del de Apple y añade un eslabón sin necesidad.

**Decidido: Citadel se queda en la serie 0.11** (`minorVersion: 0.11.0` en `project.yml`;
resuelve a la 0.11.1), que usa el fork de **Joannis, el autor de Citadel**: la cadena más corta y
con un responsable identificable. Comprobado en `Package.resolved`: `swift-nio-ssh` sale de
`github.com/Joannis/swift-nio-ssh`, versión 0.3.5.

**Antes de subir de versión**, mirar de qué fork tira la nueva en su `Package.swift`.

---

## Estructura

`PhoneRootViewController` es UIKit **a propósito**: `registerSceneAccessory(_:)` es un método de
`UIViewController`. La interfaz de dentro sí es SwiftUI, embebida con `UIHostingController`.

---

## Siguiente paso

1. **Que Bruno pruebe en el iPhone** lo de la lista de "Escrito y sin probar", empezando por lo
   del 22-sep.
2. Mientras tanto, lo pequeño de "Pendientes": Cmd+clic al navegador propio y el lanzador
   completo.
3. Cerrar la Fase 4: copiar carpetas con progreso y arrastrar entre ubicaciones.
