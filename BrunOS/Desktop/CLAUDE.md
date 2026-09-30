# Escritorio y pantalla externa

El gestor de ventanas, las barras, el dock, las ventanas modales y los ajustes del monitor. Las
reglas que valen para todo el escritorio están en el CLAUDE.md de la raíz («Reglas»); aquí va el
porqué y cómo funciona cada cosa.

## Colores y claro/oscuro

- **`UIColor.cgColor` resuelve un color dinámico con el modo del instante** y ahí se queda. Las
  capas del escritorio se crean antes de que exista el view controller que fija el modo: con el
  iPhone en claro salían con colores claros, y el cursor (color `text`) quedaba casi negro sobre
  el fondo oscuro. De ahí `UIColor.desktopCGColor` (`Tokens.swift`). El cursor va siempre en
  oscuro (claro con borde negro), que se ve en los dos modos.
- **`DesktopTheme`** (en `Display/`): por defecto sigue al iPhone; en Ajustes se fija claro u
  oscuro. El modo del teléfono lo apunta `PhoneRootViewController` con `registerForTraitChanges`:
  la escena externa no lo hereda de forma fiable. El terminal va siempre oscuro.
- Lo que se pinta en `draw(_:)` se repinta solo al cambiar de modo (`applyTheme` hace
  `setNeedsDisplay` en todo el árbol, minimizados incluidos). **Lo que se asigna a una capa**
  (`borderColor`, `backgroundColor` de un `CALayer`) hay que reasignarlo en
  `DesktopViewController.applyTheme()`, o usar `view.setThemedBorder(color)`.

## Densidad y nitidez

- `contentsScale` es la densidad exacta, `screen.scale * factor`. `applyContentsScale` la pone en
  todo el lienzo en cada maquetación, salvo en `WKWebView`, `PDFView`, `UIVisualEffectView` y
  `OverviewThumbnail`. Las capas que dibujan ellas mismas llevan filtro `.nearest`; las ventanas y
  el dock, marcos a píxel entero (`pixelAligned`).
- **Los bordes, a píxeles enteros**: uno de 1,5 pt a 1,5× son 2,25 píxeles y se veía como una
  línea doble en las esquinas. `applyContentsScale` los redondea; repetirlo da lo mismo.
- **A 1,5×, un punto son 1,5 píxeles**: lo que cae en x = 301 empieza a medio píxel y, con
  `.nearest`, las letras salen dentadas. Las tarjetas del tiempo, el calendario y el menú se
  alinean con `pixelAlignCards` al abrirse; las etiquetas de la barra, con
  `PixelSnappingStackView`. **Una modal nueva colocada a partir del cursor o de un centro, con
  `pixelAlignCards`.**
- **Lo que se añade al lienzo fuera de la maquetación** (menú, diálogos, historial, lanzador,
  Exposé, tiempo, calendario, vista previa…) nace con la densidad de la pantalla: por eso
  `applyContentsScale` justo después de añadirlo, o `matchCanvasDensity(_:)` para lo que llega
  tarde (la vista previa al terminar de bajar).

## Ventanas: `CardView` y dibujar

- **Nada se dibuja en la vista que tiene la tarjeta como subvista**: una vista pinta su contenido
  debajo de sus subvistas, y la tarjeta, opaca, lo tapaba (los ajustes salían vacíos). Dibuja la
  propia `CardView` con `drawContent`.
- `CardView` pinta ella el fondo y lo recorta a la forma redondeada (`masksToBounds` se comería la
  sombra; lo de `draw(_:)` no respeta `cornerRadius`).
- **`CardView` entrega el contexto en coordenadas de la ventana**: quien dibuje desde la esquina
  de la tarjeta hace `translateBy(card.frame.origin)` (el desplegable del tiempo salía de un
  color plano por esto). Los menús, el historial y los formularios ya suman el origen.
- **Las zonas pulsables se apuntan al dibujar**, en el mismo cálculo, para que lo que se ve y lo
  que responde no se desalineen.

## Ventanas modales

Menú contextual, diálogos (`PromptWindow`, `presentConfirm`, que acepta `isDestructive: false`),
formulario de máquinas y servidores (`FormWindow`), historial, lanzador, vista previa, Exposé,
tiempo y calendario. **Todas conforman `ModalWindow` y están en `openModals`**, la única lista,
ordenada de la de más arriba a la de más abajo: la usan el puntero, el teclado, el cursor,
`performOverModal`, los marcos de `layoutCanvas` y el apilamiento de `arrangeFloating`. **Una
modal nueva**: su propiedad, conformar `ModalWindow` y añadirla a `openModals` en su sitio. El
aviso del iPhone (`PhoneNotice`) no es modal: no se queda el ratón, sólo va encima de todo.

- Los atajos con Cmd se ejecutan en `perform(_:)` antes de que la tecla llegue a nadie. Con una
  modal abierta, Cmd+V pegaba en el terminal de detrás (y un salto de línea ahí es una orden que
  se ejecuta). `performShortcut` —la entrada del teclado; **no `perform`**, que lo llaman las
  propias ventanas— los pasa por `performOverModal`, que los desvía a la modal o los ignora.
- Los campos de texto son propios, no `UITextField`: en la pantalla externa no hay first
  responder. El teclado llega por `KeyboardRouter` y se reparte a mano, con Tab entre campos. Lo
  que se escribe sale de **`KeyEvent.typedText`, nunca de `key.characters`**: flechas, Supr y
  teclas de función traen caracteres del área privada de Unicode. Los campos escriben siempre al
  final (no hay cursor dentro del texto).
- **Todo lo que se ve tiene que poder pulsarse** (principio de Bruno). Como no hay eventos del
  sistema, cada vista expone un `hit(at:)` y el escritorio pregunta por geometría.

## Un solo escritorio, dock y ventanas

- **Un solo escritorio** (`DesktopModel.active`). Había tres espacios, uno por app, y nunca se
  veían dos apps a la vez. Cmd+1…5 abren navegador, terminal, Ficheros, Notas y Fotos, como pulsar
  su icono. **Los paneles nuevos flotan por defecto** (Ajustes › General › Ventanas).
- **El dock es el de macOS**: un icono por app, punto debajo si está abierta (ámbar la que se ve,
  gris las demás; lo minimizado cuenta). Clic: trae la app delante y, si ya lo estaba, abre otra
  ventana; cerrada, la abre. Botón derecho: «Nueva ventana» y la lista de las abiertas. Cmd+N,
  nueva ventana de la app de delante.
- **Transparencia, agrandamiento y rebote**: el fondo es `BarBackdrop` (desenfoque del sistema y
  tinte), con la cantidad en Ajustes › General › Transparencia (deslizador de 0 a 100 %, un
  solo material para que no salte al moverlo), igual que la barra superior. Los
  iconos crecen hasta ×1,25 (sutil, Bruno no lo quería enorme) con caída en coseno² hasta 2 iconos
  a cada lado, **medida desde las posiciones sin agrandar** (si no, tiembla). Cada icono se dibuja
  una vez a tamaño máximo y sólo se escala. `Dock.contains(point:)` cuenta lo que sobresale.
- **Tres bolitas** (`WindowControls`): rojo cierra, amarillo al dock (sigue vivo: la sesión SSH no
  se corta), verde maximiza. Cmd+Intro maximiza dentro del mosaico.
- **Pantalla completa** (Ctrl+Cmd+F): sin dock ni barra; asoman al llevar el cursor al borde. El
  dock también se esconde cuando una ventana pisa su sitio (`dockIsCovered`).
- **Flotantes y mosaico**: un panel está en uno de los dos (`Workspace.floating` y
  `floatingOrder`). Se suelta del mosaico arrastrando la parte vacía de su barra (umbral de 8 pt);
  doble clic en la barra o Cmd+Mayús+Espacio alterna. Bordes de 6 pt para redimensionar, mirados
  antes que el contenido. Un arrastre en curso manda sobre el dock y la barra. Sombras en una vista
  aparte (los paneles recortan su contenido).
- **Encajar**: soltar con el cursor en un borde deja media pantalla, un cuarto (esquinas de
  120 pt) o entera (arriba), con `snapPreview` detrás. El marco anterior se guarda en
  `zoomRestore`, el mismo del verde. Con dos mitades, una tercera en una esquina parte la mitad de
  ese lado (`makeRoom`; reconoce las mitades con tolerancia). Redimensionar una encajada arrastra
  a las que tocan ese borde (`linkedResize`). Hueco entre ventanas de 4 pt; divisores con 3 pt de
  margen, sólo si hay ventana al otro lado.
- **Ajustes es una ventana más** (`SettingsPane`, con `SettingsWindow` en modo `embedded`): una a
  la vez, `PaneKind.of` da `nil` (no es app del dock), no se recuerda al arrancar.
- **Al arrancar** vuelve el escritorio de la última vez (`SessionStore`, `desktop-session.json`):
  marcos (en proporción si cambia la escala), minimizadas, foco, pestañas (sólo carga la que se
  ve), máquinas del terminal (reconecta) y carpeta de Ficheros. Se guarda 2 s después de cada
  cambio y al irse a segundo plano. «Escritorio vacío» en Ajustes no abre nada. Del mosaico se
  recuerda qué había, no el árbol exacto.
- **Exposé (Cmd+E) y conmutador (Cmd+º)**: `WindowOverview`. Cmd+Tab lo reserva iOS. La tecla
  del conmutador se reconoce por su código (`º` en español, `` ` `` en inglés, y la de al lado de
  la Mayúscula en los ISO de Apple). Soltar Cmd confirma (`.endWindowSwitch`), y por si iOS no
  avisa, también el primer movimiento del ratón sin Cmd. Las miniaturas son
  `snapshotView(afterScreenUpdates: false)`.

## La barra superior

Marca (abre el lanzador), título de la ventana con foco (nada si no hay ventanas), Tailscale, el
tiempo, resolución (lleva a Ajustes › Pantalla), batería y hora (abre el calendario). Fondo
`BarBackdrop`, opaco por defecto; su raya de abajo se transparenta con ella (sola, con mucha
transparencia, se veía como una línea blanca).

- **Tailscale**: logo de nueve puntos, la «T» encendida si `TailscaleMonitor` ve una `utun` con
  dirección de Tailscale (una deducción). Se mira al cambiar la red y cada 10 s. **iOS no deja que
  una app encienda la VPN de otra**: «Conectar/Desconectar» lanza el atajo **«BrunOS Tailscale»**
  de Atajos (Bruno lo tiene creado; alterna la VPN) y vuelve por `brunos://tailscale-ok`. Mientras
  corre, el monitor enseña un momento la pantalla duplicada.
- **El tiempo**: Open-Meteo, sin clave (WeatherKit pide activar el servicio en el App ID y otro
  permiso de firma). Ciudades por nombre, no por ubicación (el aviso de permiso saldría en el
  iPhone, en negro); coordenadas a dos decimales. **Hasta 6 ciudades** (`WeatherService.places`);
  botón derecho o rueda sobre el icono para cambiar; en el desplegable, pestañas, ← → y
  Añadir/Quitar, y **también en el menú del botón derecho** (Bruno: quitar tan a mano como
  añadir). Quitar quita la que se ve. La ciudad única de antes (`weather.place`) se pasa a la
  lista en el `init`, **guardándola a mano**: ahí no salta el `didSet` y se perdía. Cada 20 minutos y al abrir el
  desplegable. Colores de la interfaz (el cielo fijo del Golden Gate no le cuadraba a Bruno).
- **Calendario** (`CalendarPopover`): el mes de lunes a domingo, fin de semana en rojo, flechas y
  rueda para pasar de mes. No lee el calendario del iPhone (permiso en la pantalla del teléfono).
- **`PhoneNotice`**: aviso en el monitor cuando hay que mirar el iPhone (selectores, Atajos); se
  va a los 7 s.

## Ajustes del monitor

Imitan Ajustes del Sistema: secciones a la izquierda, grupos con interruptores, segmentados y
botones, descritos en `SettingsPages` y pedidos de nuevo tras cada cambio. La rueda del dock abre
lo global (General, Pantalla, Ratón y teclado, Atajos, Acerca de, Rendimiento); cada panel tiene
su rueda. Casi sin deslizadores: con un cursor propio, arrastrar es menos cómodo que pulsar;
el único es la transparencia, que Bruno pidió así (`.slider`). Mientras el botón está pulsado,
Ajustes se queda con el ratón (`settingsCapture` en `processPointer`), para que un deslizador
siga al cursor fuera de la ventana. `SettingsPages.
shortcutsPageIndex` es la página de Atajos (AssistiveTouch y Tailscale).

## Lanzador (Cmd+P) y Buscar (Cmd+F)

- El lanzador busca a la vez en máquinas SSH, ubicaciones de Ficheros, favoritos, historial y
  acciones; lo escrito se ofrece como dirección o búsqueda. `addPane(.terminal)` lleva
  `autoStart` para no entrar en bucle con el lanzador.
- `FindBar`, la misma en los tres paneles: `WKWebView.find` en el navegador (el total se cuenta
  aparte), la búsqueda de SwiftTerm en el terminal, filtro por nombre en Ficheros.

## Rendimiento

Ajustes › Rendimiento (`PerformanceMonitor`): fotogramas por segundo, el más lento, maquetaciones
por segundo, memoria (`phys_footprint`, `os_proc_available_memory`), pestañas despiertas y el
registro de sucesos (`EventLog`). Sólo mide con esa página abierta.

- **`notifyChange()` recoloca el escritorio; `notifyTitleChange()` sólo repinta la barra.** Un
  cambio de título, de pestaña o de selección va por el segundo.
- **`layoutCanvas()` lleva un cerrojo de reentrada**: varias cosas de dentro avisan de cambios que
  vuelven ahí, y sin él un aviso mal puesto es recursión infinita y la app se cierra sin rastro
  (pasó con `WallpaperStore.apply`, que además decodificaba el HEIC en cada clic; ahora cachea la
  imagen y la última capa pintada).
- El cursor pausa su `CADisplayLink` tras medio segundo quieto (no entre fotogramas: daba tirones).
- **Los movimientos del ratón se entregan uno por fotograma** (`deliverPointer` los junta y
  `PointerController.onFrame` los suelta); clics y rueda, al momento, tras el pendiente.
- **Arrastrar o redimensionar una flotante no maqueta el escritorio**: `placeFloatingWindows`
  mueve esa ventana y su sombra, y la maquetación completa llega al soltar.
- `DesktopViewController` tiene dos extensiones: `+Snap.swift` (encajar) y `+TopBar.swift`
  (Tailscale, tiempo, calendario, avisos del iPhone). Las propiedades con estado viven en el
  principal, porque una extensión no puede guardarlas.

## Fondo de escritorio

**El fondo del iPhone no se puede leer** (no hay API, es privacidad). Degradados propios por
código en `Wallpaper.swift` (con resplandor radial; el de serie es `goldenGate`), fondos de macOS
copiados por `Tools/fetch-wallpapers.sh` (no se versionan: son de Apple) con un velo oscuro del
35 %, o una foto propia: desde Ficheros («Usar como fondo») o desde el iPhone con `PhotosPicker`;
se copia a Application Support reducida a 3840 px.
