# BrunOS — contexto del repositorio

App iOS personal (**no va a la App Store**, se instala por TestFlight como tester interno) que
convierte un iPhone 17 en un escritorio sobre un monitor externo, manejado con ratón y teclado
Bluetooth. No duplica la pantalla del teléfono: dibuja en la externa a resolución nativa.

Tres funciones: **terminal SSH** por Tailscale, **navegador** con pestañas y bloqueo de anuncios,
y **gestor de ficheros** (iPhone, iCloud Drive, USB y SFTP). El iPhone queda de mando: trackpad de
emergencia, teclado, dictado y ajustes.

---

## Rama `claude/bold-newton-nxodpq` (nube, 24-sep-2026, noche): compilada y en `main`

Cuatro bloques escritos en Linux sin compilador: el **bloqueador con las listas de uBlock**, los
**avisos de cookies** con las reglas de «I Still Don't Care About Cookies», **Fotos** (quinta app
del dock, Cmd+5) y la **pantalla completa de vídeo** del navegador. Cada uno, en su CLAUDE.md.

- **Al compilar en el Mac sólo falló una cosa**: `CookieNoticeBlocker.source` se leía desde una
  función `nonisolated`; ahora es `nonisolated static let`. Cero warnings.
- **En el simulador**: el bloqueador bajó las listas y WebKit compiló las 4 sin rechazar ninguna,
  **169.903 reglas**, en unos 10 s la primera vez. Las reglas de cookies también se bajaron. Fotos y
  la pantalla completa de vídeo necesitan el monitor: **sin probar**.
- `BrunOS/Resources/Blocklists/` se borró del Mac: las listas se bajan ahora en el iPhone, y como
  `.gitignore` ya no las ignora, se habrían colado en un repositorio público.
- **Riesgo aceptado por Bruno** (24-sep): los scripts de los avisos de cookies se bajan de la rama
  `master` del repositorio de OhMyGuus y corren en todas las páginas, en su propio mundo de
  contenido. Si alguien comprometiera ese repositorio, su código correría en todas las webs. Se
  le explicó y dijo que lo acepta por el bloqueo de cookies. **No cambiarlo sin preguntarle.** Las
  listas de anuncios, en cambio, son reglas declarativas y no ejecutan código (el conversor tira
  los scriptlets `##+js`).

## ⚠ ESTADO ACTUAL — LEER PRIMERO (24-sep-2026, tarde)

**Última build subida: 2609241727 (24-sep-2026, tarde)**: el ratón (el toque de AssistiveTouch
ya no se toma por un dedo; preferencia de fuentes como en la 2609241352), RedGifs dentro de
Reddit, el PDF dibujado por BrunOS, los bordes a píxeles enteros, la vista previa con la densidad
del lienzo y el scroll del terminal. **Sin probar en el iPhone.**

**Anterior: 2609241652 (24-sep-2026, tarde)**: todo lo de `main` a las 16:50. Lo
nuevo: la rama de la nube (bloqueador de uBlock, avisos de cookies, Fotos, pantalla completa de
vídeo), el ratón que se atascaba (manda el puntero indirecto), fuera las contraseñas, la selección
del terminal, el PDF, el tercer encaje, el hueco de 4 pt, el botón de historial y el «125 %».
**Nada de eso probado en el iPhone.**

**Anterior: 2609241450 (24-sep-2026, tarde)**: todo lo de la tarde (modo mando
negro, tiempo con colores de la interfaz, avisos de «mira el iPhone», Ajustes › Atajos, calendario,
iCloud y vídeo por SFTP/SMB). Lo que falta por probar está en «Pendiente de probar en el iPhone».

**Anterior: 2609241352 (24-sep-2026, tarde)**: lo de la 2609241157 más lo que iba
«sin subir» justo debajo. **Lo nuevo de esta, sin probar en el iPhone.**

**Anterior: 2609241157 (24-sep-2026, mediodía)**, con lo de la nube (abajo) y los arreglos de
«Lo que Bruno vio en la 2609240858».

**Visto bien en la 2609241157** (24-sep): Notas y la barra superior (Tailscale y el tiempo en la
barra; el desplegable del tiempo no, ver abajo).

**Subido en la 2609241352** (antes iba sin subir): el desplegable del tiempo, que salía de un
color plano (dibujaba fuera de su tarjeta); las sugerencias de la barra de direcciones, con el
texto desplazado por lo mismo; los nombres largos de la barra lateral de Ficheros, con «…» y la
barra a 180 puntos; el icono de Tailscale comprobado cada 10 segundos; y el texto que explica el
atajo «BrunOS Tailscale» (alterna la VPN); y **el iPhone en blanco y el ratón mal al volver de
Atajos** (ver «Al volver de Atajos»), con el registro de sucesos en Ajustes › Rendimiento.

**Visto bien por Bruno en la 2609241157, todo lo demás** (24-sep por la tarde): las cinco cosas de
la 2609240858, Exposé, el conmutador, fijar y silenciar, la selección múltiple y el progreso de
Ficheros, recordar el escritorio, Notas y la barra superior.

**Para seguir en el Mac** (rama `claude/admiring-mendel-ncfej4`, ya juntada con `main`). Todo lo de la
tarde del 24-sep se escribió en una sesión de Linux **sin Xcode ni compilador**; sólo se pasó un
análisis de sintaxis (tree-sitter) y una revisión a mano del diff. Por orden:

1. ~~`git pull` de la rama y `./Tools/build.sh`.~~ **Hecho en el Mac el 24-sep** (commit d687c59,
   ya en `main`): sólo fallaban `isFocused` en Notas (choca con la de `UIView`, ahora `hasFocus`)
   y la inferencia de las closures de progreso en `FileService`. Compila sin warnings. Que compile
   no dice que funcione. Lo menos seguro: `WKWebView.requestMediaPlaybackState()` (altavoz de las pestañas), las
   firmas de progreso de AMSMB2 (comprobadas contra su `master`), `UITextDirection.storage(_:)` y
   la geometría de `UITextInput` en el editor de Notas, y el aislamiento de los cierres
   `@MainActor` que se pasan a `ProgressThrottle`.
2. Mantener **cero warnings** en código propio, como hasta ahora.
3. Probar en el simulador lo que se pueda (Notas, el tiempo, Ficheros con varias ventanas) y
   luego en el iPhone. **Avisar a Bruno antes de subir a TestFlight.**
4. Crear en Atajos el atajo «BrunOS Tailscale» (ver «Tailscale y el tiempo en la barra»).

Lo que lleva: fijar y silenciar pestañas; Ficheros con ubicación propia por ventana, selección
múltiple y progreso por bytes; Exposé (Cmd+E) y conmutador (Cmd+º); los clics con modificadores
(`KeyboardRouter.heldModifiers`); la app de Notas y portapapeles (Cmd+4); Tailscale y el tiempo en
la barra superior. Cada cosa, en su sección y en los CLAUDE.md de cada carpeta.

## Historial del estado (23-sep-2026)

**23-sep-2026**: subida la 2609231826. Bruno confirma que **el ratón funciona** (clic y
arrastre) y que **lo pendiente de antes también** (ratón conectado que se desmarca, salir del
modo mando al quitar el monitor, nombre de carpeta). El SMB por la app Archivos funciona, pero le
parece un proceso de conexión muy complicado. Queda abierto: el reCAPTCHA de Google (arreglado
en la siguiente build, ver `BrunOS/Browser/CLAUDE.md`) y unas esquinas que salen mal en los
ajustes de Ficheros, aún sin localizar.

**La 2609232025 no arranca en el iPhone** (lo vio Bruno el 23-sep por la noche): enlazaba
`AMSMB2.framework` pero no lo llevaba dentro, y dyld la cerraba al abrirla. En el simulador no se
nota. Arreglado con `embed: true` en `project.yml`, y `testflight.sh` ahora se niega a subir si
falta un framework. **Hay que subir otra build** (avisando antes) para que pruebe todo lo de abajo.

**Última build subida: 2609232124 (23-sep-2026, noche)**: arregla el arranque y añade un solo
escritorio con las tres apps juntas, las esquinas de las ventanas y la descarga de RedGifs. La
anterior, 2609232025, no arrancaba y llevaba todo lo del día: reCAPTCHA
(reenvío a iframes por Swift), SMB propio, menú del dock, copia por trozos, cursor de
redimensionar, HLS, historial y los arreglos de la revisión.

**Para retomar:**

1. Que Bruno pruebe la 2609232124 (lleva todo lo de la 2609232025): el reCAPTCHA, el SMB propio, varias ventanas desde el dock,
   el historial (Cmd+Y), descargar un vídeo HLS, el cursor de redimensionar y, de antes, barra de
   favoritos, sugerencias, modo lectura, el ⤓ de descargas y guardar como PDF.
2. Las esquinas de los ajustes de Ficheros y ver varias apps a la vez (arreglados el 23-sep por la
   noche, sin subir).
3. Probar el SMB propio (AMSMB2, 23-sep-2026): Ajustes de Ficheros › Ubicaciones › Nuevo
   servidor. Escrito y compilado, **sin probar contra un servidor de verdad**.
4. Navegador hacia «un Safari», por orden: restaurar la sesión al arrancar, navegación privada,
   zoom por sitio, silenciar y fijar pestañas. La ventana de historial (Cmd+Y) ya está.

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

## Pendiente de probar en el iPhone (lista única, al 24-sep-2026 con la 2609241727)

Bruno prefiere acumular y probarlo todo junto; conviene no confundir «está escrito» con
«funciona». **Esta es la lista buena**: las marcas «sin probar» repartidas por los CLAUDE.md
pueden estar viejas. Al confirmar algo, se quita de aquí.

**Navegador**
- **Bloqueador con las listas de uBlock** (24-sep; compila y compila las listas en el
  simulador): que baje y compile las listas en el iPhone, que desaparezcan los recuadros grises y
  cuánto tarda la primera vez. Ver `BrunOS/Browser/CLAUDE.md`.
- **Avisos de cookies** con las reglas de «I Still Don't Care About Cookies» y la galleta de la
  barra (24-sep; compila).
- Descargas de vídeo de la página, el gestor ⤓ y los HLS; «Descargar vídeo» en RedGifs.
- El login de Reddit (y cualquier otro): sin la hoja de contraseñas, que tapaba el trackpad;
  la lógica de contraseñas está quitada entera (Bruno las escribe a mano).
- Plex.
- **Pantalla completa de vídeo** en YouTube y Plex (24-sep; compila): el botón y la F de
  YouTube, Esc para salir, y que la barra del vídeo no saque el dock.
- El botón de historial en la barra y el indicador de zoom («125 %» un segundo).

**Fotos** (24-sep, escrito en Linux; compila)
- La app entera: rejilla, miniaturas (también por SFTP/SMB), visor, vídeo con su barra, pase de
  diapositivas, «Abrir en Fotos» desde Ficheros, el icono y Cmd+5.

**Terminal**
- tmux y vim con ratón.
- Seleccionar arrastrando: **marcaba lejísimos del cursor** (filas visibles frente a filas del
  historial); arreglado en la 2609241652.
- `known_hosts` ante una clave que cambie, y la reconexión tras una caída real.
- Entrar con clave ed25519, e importar una clave cifrada.

**Ficheros**
- SMB propio contra un servidor de verdad, y el vídeo por SFTP/SMB mientras llega.
- La vista previa de PDF: **salía mal** (sin ajustarse, una página, borrosa); rehecha en la 2609241652.

**Escritorio y entrada**
- **El ratón iba peor y se atascaba antes del borde** (Bruno, 24-sep, en la 2609241450): mandaba
  `GCMouse` en vez del puntero indirecto (ver «El ratón se atascaba en el borde»); en la 2609241652.
- El hueco entre ventanas, de 8 a 4 puntos, y el tercer encaje en una esquina que hace sitio;
  en la 2609241652.
- El dictado, el teclado en pantalla y el overscan.
- Las escalas nuevas: 1,25×, 1,75× y 2,25×.

**Confirmado por Bruno el 24-sep, en la 2609241652**: el login de Reddit, el bloqueador con las
listas de uBlock, los avisos de cookies (parece), la selección del terminal y la rueda y las
páginas del PDF. **No**: la resolución del PDF (rehecho), RedGifs dentro de Reddit (arreglado), el
ratón (arreglado), y los marcos de las ventanas con línea doble (arreglado).

**Confirmado por Bruno el 24-sep**: todo lo nuevo de la 2609241450 (modo mando, Atajos, «mira
el iPhone», calendario, tiempo, renombrar, iCloud, Tailscale cada 10 s), el cursor de
redimensionar, los divisores, Cmd+P, Cmd+F, la nitidez (parece), la barra de favoritos y los
iconos, guardar como PDF, Ficheros salvo la vista previa de PDF, volver a pulsar el dock, barras, quitar ubicaciones, cookies
de Google (parece), scroll, Notas, la barra superior, el tiempo, las sugerencias, la barra lateral
de Ficheros, el fondo al reconectar, la nitidez, encajar ventanas y el dock que se aparta,
redimensionar juntas, Ajustes como ventana, Exposé, el conmutador, fijar y silenciar pestañas,
selección múltiple y progreso en Ficheros, y recordar el escritorio.

## Cómo se cierra cada bloque de trabajo

Lo pidió Bruno el 22-sep-2026: **cada bloque que compile sin errores termina en commit, `git push`
y README y memoria al día**, sin preguntar en cada paso. Antes del push, revisar el diff por si se
cuela algo sensible: el repositorio es público.

**La subida a TestFlight, en cambio, se avisa antes y se espera el visto bueno** (23-sep-2026:
«no subas más compilaciones sin avisar para no bloquear»). Cada subida gasta del límite diario de
App Store Connect, y si se agota, Bruno se queda sin poder probar hasta el día siguiente.

## Dónde está el resto

Lo de cada parte vive junto a su código y se carga sólo al trabajar allí:

- `BrunOS/Terminal/CLAUDE.md`: SSH, Citadel, `known_hosts`, keyboard-interactive, el tema del terminal.
- `BrunOS/Browser/CLAUDE.md`: WebKit, el inyector de clics y teclas, descargas, el bloqueador y
  sus restricciones.
- `BrunOS/Files/CLAUDE.md`: orígenes de ficheros, marcadores de seguridad, la vista previa propia.
- `BrunOS/Phone/CLAUDE.md`: el único puente a Objective-C (`installTap`).
- `BrunOS/Notes/CLAUDE.md`: las notas, el editor propio y el historial del portapapeles.
- `BrunOS/Photos/CLAUDE.md`: Fotos, el visor de imágenes y el reproductor de vídeo de una carpeta.
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

### Lo que Bruno vio en la 2609240858 (24-sep-2026)

Confirmado en el iPhone: volver a pulsar el dock, las barras, quitar ubicaciones, las cookies
(parece) y el scroll. Arreglado después, **sin subir** (pidió no subir todavía):

- **El fondo no aparecía al reconectar el monitor**: `WallpaperStore.apply` recordaba lo último
  pintado sin mirar en qué capa, y el escritorio nuevo trae la suya vacía. Ahora apunta la capa,
  y el escritorio invalida la caché al crearse.
- **Seguía un poco borroso**: `contentsScale` era `screen.scale * max(factor, 1)`, y con un
  monitor que iOS ve como Retina, a 1,5× se dibujaba a 2 píxeles por punto y se reducía. Ahora es
  la densidad exacta, `screen.scale * factor`. Además las ventanas y el dock van a píxel entero
  (`pixelAligned`) y las capas que dibujan ellas mismas usan filtro `.nearest`, para que medio
  píxel de desplazamiento no las emborrone. **Sin probar en el iPhone**; si sigue, lo siguiente
  es mirar en el log el `contentsScale` y el `scale` de la pantalla.
- **El hueco del dock al encajar**: lo encajado llega hasta abajo, y el dock se esconde solo
  cuando una ventana pisa su barra (`dockIsCovered`), como con pantalla completa: asoma al llevar
  el cursor al borde de abajo.
- **Redimensionar una encajada movía sólo esa**: ahora las que tocan el borde que se arrastra (a
  la distancia del hueco o menos) lo siguen (`linkedResize`); si una ya no puede encoger, se para.
- **Ajustes siempre encima**: ahora es una ventana más (`SettingsPane`, con `SettingsWindow` en
  modo `embedded`), que se mueve, se encaja y queda detrás de otras. Una sola a la vez;
  `PaneKind.of` devuelve `nil` para ella (no es app del dock), no se recuerda al arrancar y el
  amarillo la cierra.

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

**Un solo escritorio** (23-sep-2026, noche). Había tres espacios, uno por app (`1 web`, `2 ssh`,
`3 files`), y el dock cambiaba de espacio al pulsarla: abrir el terminal escondía el navegador y
**nunca se veían dos apps a la vez**, aunque hubiera ventanas flotantes. Primero se hicieron
genéricos y luego Bruno pidió quitar los otros dos: con flotantes, dock y lanzador sólo servían
para esconder ventanas. Ahora `DesktopModel.active` es el único `Workspace`; el dock tiene un
icono por app (`PaneKind.dockOrder`) y **Cmd+1/2/3 abren navegador, terminal y Ficheros**, como
pulsar su icono. **Los paneles nuevos flotan por defecto.**

**Al arrancar** (24-sep-2026) vuelve el escritorio de la última vez (`SessionStore`,
`desktop-session.json`): cada ventana con su marco (en proporción si cambia la escala), las
minimizadas, cuál tenía el foco, las pestañas del navegador (**sólo carga la que se ve**; las
demás esperan dormidas, `prepareSuspended`), las máquinas del terminal (**vuelve a conectar**)
y la carpeta de Ficheros. Se guarda 2 s después de cada cambio y al irse a segundo plano. Si en
Ajustes › General › Ventanas se elige «Escritorio vacío», o no hay nada guardado, **no se abre
nada** hasta pulsar el dock: lo pidió Bruno. Antes salía una ventana de cada app. Del mosaico se
recuerda qué había, no el árbol exacto de divisiones. **Sin probar en el iPhone.** Abrir algo desde otro sitio (historial, «Mostrar en Ficheros», el lanzador) usa
`frontmost(_:)`.

**Varias ventanas de la misma app** (23-sep-2026): botón derecho sobre su icono del dock ›
«Nueva ventana», y debajo la lista de las que tiene abiertas, minimizadas incluidas, para ir
directo a una. También Cmd+N (de la app que está delante) y «Nuevo terminal /
navegador / gestor de ficheros» en el lanzador. **El clic normal trae la app delante y, si ya lo
estaba, abre otra ventana** (24-sep-2026: Bruno volvía a pulsar el icono esperando una segunda).

### Exposé y Cmd+º (24-sep-2026)

`WindowOverview`, la misma vista en dos formas. **Sin compilar ni probar.**

- **Cmd+Tab no se puede**: iOS se lo reserva. El conmutador va con **Cmd+º**, la tecla de debajo
  de Esc (el Cmd+` de macOS), reconocida por su código y no por lo que escribe (`º` en español,
  `` ` `` en inglés; también la de al lado de la Mayúscula, que los ISO de Apple intercambian).
  Mientras se mantiene Cmd, cada pulsación pasa a la siguiente (con Mayús, a la anterior); al
  soltar Cmd se va a la elegida. La primera pulsación lleva a la ventana de antes:
  `Workspace.recent` guarda el orden de uso, minimizadas incluidas.
- **Soltar Cmd** llega como la tecla `keyboardLeftGUI` que sube (`.endWindowSwitch`). Por si iOS
  no la entregara, el primer movimiento del ratón sin Cmd pulsado (`heldModifiers`) también
  confirma, y cualquier otra tecla también.
- **Exposé (Cmd+E**, o desde el lanzador): todas las ventanas en una rejilla, la que deja las
  miniaturas más grandes. Clic o Intro para ir, Esc o clic en el fondo para salir.
- Las miniaturas son `snapshotView(afterScreenUpdates: false)`, no las vistas de verdad. Las
  minimizadas y las tapadas por una maximizada salen con el icono de su app. El hueco de la foto es
  `OverviewThumbnail`, que `applyContentsScale` se salta: con `.nearest` la foto encogida saldría a
  trozos.
- Es una modal más: está en las tres listas (puntero, cursor y `performOverModal`) y en
  `deliverKey`.

### Tailscale y el tiempo en la barra (24-sep-2026)

**Sin compilar ni probar.**

- **Tailscale**: el icono va en verde si `TailscaleMonitor` ve una interfaz `utun` con dirección
  de Tailscale, en gris si no (es una deducción). Se mira al cambiar la red **y cada 10 segundos**
  (Bruno, 24-sep): el aviso de red no siempre llega al tocar la VPN desde fuera. **iOS no deja que una app encienda la VPN de
  otra** (`NEVPNManager` sólo gestiona las de la propia app), así que «Conectar/Desconectar» lanza
  el atajo **«BrunOS Tailscale»** de la app Atajos, el mismo camino que el de AssistiveTouch, y
  vuelve por `brunos://tailscale-ok`. Bruno tiene que crear ese atajo una vez con la acción de
  Tailscale que **activa o desactiva** la VPN (así lo tiene Bruno desde el 24-sep: el atajo
  alterna y no mira el `on`/`off`, así que no hace falta un «Si»). El menú lo explica y abre
  Atajos. Se le pasa `on`/`off` como entrada. Mientras
  corre, el iPhone pasa un momento por Atajos y el monitor enseña la pantalla duplicada.
- **El tiempo**: Open-Meteo, gratis y sin clave. No WeatherKit: habría que activarlo en el App ID
  desde el portal y añadir un permiso a la firma. La ciudad se elige por nombre (búsqueda de
  Open-Meteo; si hay varias, un menú), no por ubicación: el aviso de permiso saldría en la
  pantalla del iPhone, en negro. Coordenadas redondeadas a dos decimales. Se actualiza cada 20
  minutos y al abrir el desplegable.
- **El desplegable salía de un color plano y sin nada que pulsar** (Bruno, 24-sep, en la
  2609241157): dibujaba en coordenadas de la tarjeta, pero `CardView` entrega el contexto en
  coordenadas de la ventana (ver «Los ajustes salían vacíos»), así que todo caía fuera del
  recorte. Ahora compensa con `translateBy`, como `SettingsWindow`. **Quien use `CardView` y
  dibuje desde la esquina de la tarjeta tiene que hacer lo mismo.** Las sugerencias de la barra
  de direcciones tenían el mismo fallo (texto desplazado) y ya está; los menús, el historial, los
  formularios y el diálogo de texto sí sumaban el origen de la tarjeta.
- **El desplegable imita el widget del Tiempo de macOS con los colores del fondo Golden Gate**
  (Bruno lo pidió): degradado de azul del crepúsculo a ámbar, texto blanco y la barra de
  temperaturas en ámbar; de noche, el mismo cielo apagado. Colores fijos a propósito: no cambian
  con el modo claro u oscuro. Ahora, 8 horas y 6 días. Es modal (`weatherPopover` está en las
  listas del puntero, el cursor, `performOverModal` y `deliverKey`).
- `presentConfirm` acepta `isDestructive: false` para avisos que no borran nada.

### Rendimiento (24-sep-2026)

La ronda de optimización que pidió Bruno. **Nada medido en el iPhone todavía**: para eso está
Ajustes › Rendimiento (`PerformanceMonitor`), con fotogramas por segundo, el fotograma más lento,
maquetaciones por segundo, memoria (`phys_footprint` y `os_proc_available_memory`) y pestañas
despiertas. Sólo mide mientras esa página está abierta (`SettingsPage.isLive`).

- **Dos avisos distintos**: `notifyChange()` es para lo que mueve ventanas y recoloca el
  escritorio; **`notifyTitleChange()` sólo repinta la barra superior**. Antes todo recolocaba
  el lienzo, recorría todas las capas y repintaba el dock, también con cada paso de la barra de
  carga de una web y cada título de tmux. **Un cambio de título, de pestaña o de selección va por
  el segundo.** El recorrido de densidad (`applyContentsScale`) se programa una vez por vuelta
  en ese caso, para las vistas nuevas (una pestaña de terminal).
- `DesktopModel.didChange` ya no pasa por `applyDisplayProfile()`: sólo maqueta. La pantalla
  se vuelve a colocar con sus propios avisos.
- El cursor pausa su `CADisplayLink` cuando no hay nada que pintar.
- Los vídeos de una web se miran al cargar y cuando la página avisa (`brunosMedia`, en captura
  de `loadedmetadata`/`play`/`emptied`), no cada 3 segundos en todos los navegadores.
- Pestañas: **5 despiertas entre todos los navegadores** (antes 8 por ventana) y se duermen las
  que llevan 10 minutos sin verse. Nunca la que se está viendo.
- El historial guarda las visitas a los 3 segundos, juntas (y al irse a segundo plano); las
  miniaturas de Ficheros se repintan por tandas; el hover del navegador ignora el medio punto.

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

- **Encajar** (24-sep-2026): soltar una ventana con el cursor en un borde la deja a media
  pantalla (lados), a un cuarto (esquinas, con 80 puntos de margen a lo largo del borde) o
  entera (arriba). Mientras se arrastra se ve el hueco (`snapPreview`, detrás de la ventana). El
  marco anterior se guarda en `zoomRestore`, el mismo del botón verde: al arrastrarla otra vez
  (más de 8 puntos) recupera su tamaño bajo el cursor. Bruno pidió mitades y cuartos.

- **Hacer sitio al encajar** (24-sep-2026): con dos mitades, soltar una tercera en una esquina
  deja la de esa mitad en el cuarto que queda (`makeRoom`); una a pantalla entera pasa a la otra
  mitad. Sólo se tocan las que están exactamente encajadas.
- **El hueco entre ventanas es de 4 puntos** (antes 8; a Bruno le sobraba). Los divisores del
  mosaico se agarran con 3 puntos de margen a cada lado, y sólo si hay ventana al otro lado.

**Sin probar en el iPhone.** Sobre un borde de una flotante o un divisor del mosaico, el cursor
pasa a la doble flecha de redimensionar (`PointerController.Shape`), y la mantiene mientras se
arrastra.

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

**Volvió a atascarse el 24-sep-2026** (Bruno, en la 2609241450). Causa probable: `MouseRouter`
**prefería `GCMouse`** en cuanto entregaba algo, y desde que `KeyboardRouter` lee los
modificadores con `GCKeyboard` (sesión de la nube), GameController está en marcha y `GCMouse`
entrega desplazamientos que salen del puntero de iOS, que se para en el borde del iPhone. Ahora
**manda el puntero indirecto siempre que entregue**, y `GCMouse` queda para cuando no hay
AssistiveTouch. Ajustes › Ratón y teclado › «Fuente activa» dice cuál manda: con AssistiveTouch
tiene que poner «puntero indirecto».

**Y en la 2609241652 seguía**: el cursor se movía, pero a tirones y **chocando con el límite
del iPhone**, que es la firma de moverse por desplazamientos. La causa: el trackpad a pantalla
completa decidía si el toque de AssistiveTouch era el ratón con `isPointerWorking`, que **se
apaga solo a los 3 s** sin movimiento del puntero (y el puntero se calla con cada clic y en los
arrastres). Apagado, el toque se tomaba por un dedo y movía el cursor por desplazamientos ×1,6,
parados en el borde del teléfono; con la posición absoluta llegando a la vez, a tirones. Ahora
usa `pointerEverWorked`, que no se apaga (`TrackpadUIView.isMouseSession`). **Sin subir.**

Además, también sin subir:

- La preferencia de `MouseRouter` vuelve a la de la 2609241352 (GCMouse primero): con la que el
  ratón iba bien según Bruno. El cambio de la 2609241652 fue a ciegas. «Fuente activa» se calcula
  al momento.
- ~~Una posición del indirecto con el botón «pulsado» lo suelta~~: **quitado en la revisión**.
  El puntero indirecto también manda posiciones durante un arrastre (`handlePan`), así que
  habría soltado el botón a medias. Se vuelve a ignorar la posición mientras se pulsa.
- El refresco del cursor ya no se pausa entre fotograma y fotograma: sólo tras medio segundo
  quieto. Pausar y reanudar a cada movimiento podía dar los tirones.
- **Ajustes › Ratón y teclado › Diagnóstico**: fuente activa, eventos por segundo de cada fuente y
  **el alcance del puntero indirecto** (de 0 a 100 % en cada eje). Si no llega a 0 y 100 %, iOS no
  deja que el puntero cubra la pantalla del iPhone: es lo primero que hay que pedirle a Bruno.

**Sin probar en el iPhone.** Si la posición que da el puntero indirecto no cubre la pantalla
entera (por ejemplo, si iOS la limita al área segura), el cursor no llegaría a los bordes del
monitor: es lo primero que hay que mirar.

### Arrastrar con el ratón: el toque de AssistiveTouch es el botón

Arrastrar no funcionaba en ningún sitio. Con AssistiveTouch, el botón izquierdo llega como **un
toque en la pantalla del iPhone** donde esté el puntero, y mantenerlo mientras se mueve es un dedo
que se desliza. El trackpad a pantalla completa descartaba ese movimiento (para no mover el cursor
el doble) y sólo el clic suelto llegaba, por el reconocedor de toques. Ahora, con ratón y en modo
mando, `TrackpadUIView` trata ese toque como el ratón: al tocar, botón pulsado **donde ya está el
cursor**; al mover, el cursor se desplaza lo mismo que el toque, escalado como el puntero; al
soltar, botón suelto.

**Lo que no hay que volver a hacer**: una primera versión colocaba el cursor en el punto del toque,
suponiendo que caía justo bajo el puntero. No es así —Bruno lo vio en el iPhone—: cada clic hacía
saltar el cursor y el arrastre era imposible. **La posición del toque de AssistiveTouch no es
fiable; su desplazamiento, sí.**

### El modo mando salía blanco (24-sep-2026)

**La causa de verdad del «iPhone en blanco»**, que parecía cosa de volver de Atajos: el trackpad
a pantalla completa se pintaba con `Tokens.Color.background`, que sigue al iPhone, y **en modo
claro es casi blanco** (`F6F4F0`), tapando el negro de `RemoteModeView`. Ahora es negro fijo y
`RemoteModeView` va en oscuro siempre. Lo de volver a enganchar el monitor (abajo) se queda: es
un fallo posible aunque no fuera éste.

### Mira el iPhone, Atajos y el calendario (24-sep-2026)

- **`PhoneNotice`**: aviso en el monitor cuando algo se hace en el iPhone (el selector de
  carpetas, el paso por Atajos). Se va solo a los 7 segundos.
- **Ajustes › Atajos** junta AssistiveTouch y Tailscale, con cómo crear cada atajo, el estado y
  un botón para probar el de Tailscale. `SettingsPages.shortcutsPageIndex` es su posición; el
  «Cómo crear el atajo…» del menú de Tailscale lleva ahí.
- **Calendario** (`CalendarPopover`) al pulsar la hora: el mes, de lunes a domingo, hoy marcado,
  el fin de semana con franja y en rojo (Bruno lo pidió distinto),
  flechas, la rueda y ← → para pasar de mes. No lee el calendario del iPhone: el permiso saldría
  en la pantalla del teléfono.
- **El desplegable del tiempo** lleva ahora los colores de la interfaz y sigue el modo: el cielo
  fijo del Golden Gate no le cuadraba a Bruno.
- Las ventanas modales se traen delante en cada maquetación (`arrangeFloating`): faltaban el
  tiempo y el aviso del iPhone.

### Al volver de Atajos, el iPhone en blanco y el ratón mal (24-sep-2026)

Bruno lo vio tras encender y apagar Tailscale, que pasa por Atajos. **Sin reproducir**: esto es
lo que el código explica. Mientras BrunOS está en otra app, `updateProperties` ve el accesorio
como no disponible y `detach()` da el monitor por desconectado (fuera el cursor, el iPhone sale
del modo mando). Al volver, **iOS puede reutilizar la misma escena externa** sin llamar otra vez a
`scene(_:willConnectTo:)`, y nadie la enganchaba. Además, «Conectar» actúa al pulsar, la app se va
antes de que llegue el soltar, y si la vista del trackpad ya no estaba, `isHoldingButton` se
quedaba en `true` y **se ignoraba el movimiento del puntero** (`mouseSource(_:didMove:)`).

- `ExternalSceneDelegate.reattachIfNeeded()` vuelve a enganchar monitor y cursor **si no hay
  ninguno enganchado**: al volver al frente la escena externa, al activarse la del iPhone y cuando
  el accesorio vuelve a estar disponible (`updateProperties`).
- El botón se suelta al dejar de estar activa la app (`sceneWillResignActive`) y cuando la vista
  del trackpad sale de la ventana.
- **`EventLog`**: las últimas 30 cosas de la app y del monitor (conectar, segundo plano, vueltas
  por `brunos://`), en Ajustes › Rendimiento, porque sin Modo de desarrollador no hay log. Si
  vuelve a pasar algo así, es lo primero que hay que pedirle.

### Al desconectar, el iPhone se quedaba en modo mando

Dos causas. **`ExternalDisplayManager` no era `@Observable`**: la interfaz del iPhone decide el modo
por `currentProfile`, y al conectar funcionaba de rebote (cambiaba otra cosa observable a la vez),
pero al desconectar nada la repintaba. Y **al quitar el cable, iOS puede tardar en llamar a
`sceneDidDisconnect`**: ahora `PhoneRootViewController.updateProperties()` mira también
`UISceneAccessoryRegistration.isAvailable`, que es la fuente que iOS 27 da para esto. `detach()`
aguanta que le lleguen las dos.

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
AssistiveTouch puesto sólo para el puntero, y `GCMouse` tampoco ve el ratón en ese caso. **Un solo
criterio en todas partes**: `AssistiveTouchMonitor.isActive` y `mouseDetected`, que dan por bueno
lo que diga iOS **o** que lleguen eventos del puntero. Nunca mirar `isRunning` o `hasMouse` a pelo
en la interfaz. Los eventos se detectan también sobre la hoja de ajustes y el asistente
(`onContinuousHover`): el puntero no pasa por la vista raíz mientras hay una hoja delante, y
abriendo los ajustes nada más arrancar salía «no detectado». El estado se refresca al volver a
la app.

**«Ratón conectado» no se desmarcaba nunca**: `isPointerWorking` se ponía a `true` con el primer
evento y ahí se quedaba. Ahora `pointerMaybeGone()` lo baja si, tres segundos después de que
termine el «hover» del puntero (que es lo que pasa al desconectar el ratón), no ha llegado nada;
los tres segundos son porque el hover también termina un instante con cada clic. AssistiveTouch
activo usa otro dato, `pointerEverWorked`, que no se baja: desconectar el ratón no lo apaga. Y
`notePointerEvent()` sólo asigna lo observado si cambia: se llama en cada movimiento, y asignar
aunque fuera el mismo valor repintaba la interfaz del iPhone a cada fotograma.

### Los bordes, a píxeles enteros (24-sep-2026)

Bruno veía los marcos de las ventanas raros en las esquinas, **como una línea doble**. El borde es
de 1,5 puntos, que a 1,5× son 2,25 píxeles: uno entero, otro casi y un cuarto suavizado. Visto en
el simulador ampliando una esquina, sale como dos bandas de tono distinto, más en la curva, con
filtro de nitidez o sin él. `applyContentsScale` redondea ahora **todo borde del escritorio a
píxeles enteros** del monitor (a 1,5×, 2 píxeles justos). Redondear otra vez da lo mismo, así que
puede pasar en cada maquetación.

**Y lo que llega tarde, con la densidad del lienzo**: `matchCanvasDensity(_:)` para lo que se
añade después de maquetar. La vista previa lo usa al enseñar el fichero (imagen, texto o PDF
llegan al terminar de bajar); sin eso nacían con la densidad de la pantalla y se veían a la
resolución equivocada hasta la siguiente maquetación, que un scroll no provoca.

### Las esquinas de las ventanas: el fondo lo pinta `CardView`

Bruno vio en los ajustes de Ficheros el borde redondeado y el fondo oscuro asomando en cuadrado
por las esquinas: lo que se dibuja en `draw(_:)` no respeta `cornerRadius`, y `masksToBounds` se
comería la sombra. `CardView` se queda el `backgroundColor`, lo pinta ella y recorta fondo y
contenido a la forma redondeada. **Sin probar en el iPhone.**

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
y la edición de máquinas SSH (`FormWindow`, que también da de alta los servidores SMB). Si el iPhone está apagado, nada de esto puede
vivir allí.

El editor de máquinas lleva **campos de texto propios**, no `UITextField`: en la pantalla externa
no hay eventos del sistema ni first responder que valga, así que el teclado llega por el
`KeyboardRouter` y se reparte a mano entre los campos, con Tab para saltar de uno a otro. Es el
mismo mecanismo que la barra de direcciones del navegador.

La interfaz del iPhone sigue entera **sin monitor conectado**, que es cuando tiene sentido.

Los ajustes del monitor **no llevan deslizadores**: con un cursor propio, arrastrar uno es
incómodo, así que las filas van pasando por los valores útiles al pulsarlas.

### Con una ventana modal, los atajos no tocan lo de detrás (23-sep-2026)

Los atajos con Cmd se ejecutan en `perform(_:)` **antes** de que la tecla llegue a nadie. Con el
historial, el lanzador o un formulario abiertos, Cmd+V pegaba en el terminal de detrás (y un salto
de línea en lo pegado es una orden que se ejecuta en el servidor) y Cmd+W cerraba una pestaña que
no se veía. Ahora `performShortcut` —la entrada del teclado; **no `perform`**, que lo llaman las
propias ventanas estando abiertas— los pasa por `performOverModal`, que los desvía: Cmd+V pega en la ventana, Cmd+Intro abre en otra
pestaña desde el historial, Cmd+Y y Cmd+P cierran lo suyo, y el resto no hace nada. **Una ventana
modal nueva tiene que entrar en esa lista** (y en las otras dos: la del puntero y la del cursor).

Lo que se escribe en un campo propio sale de `KeyEvent.typedText`, **nunca de `key.characters` a
pelo**: las flechas y las teclas de función traen caracteres del área privada de Unicode, y Tab e
Intro, de control; en un buscador lo dejaban sin resultados con basura invisible.

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

- **Una ronda completa de optimización** (lo pidió Bruno el 23-sep-2026): medir y quitar lo que
  frena —repintados de más, trabajo en el hilo principal, memoria— y **proponerle cambios** que
  mejoren la respuesta y el manejo de la app. Proponer antes de hacer: es él quien decide.
- **Navegador, para parecerse más a Safari**: navegación privada, silenciar una pestaña, zoom por
  sitio, fijar pestañas y buscadores propios.
- ~~Más listas de bloqueo y quitar los recuadros grises~~: escrito el 24-sep, falta compilarlo.
- **YouTube**: sólo saldría lanzando yt-dlp en una máquina del tailnet por SSH. HLS ya se baja
  (`HLSDownloader`, 23-sep-2026).


## El bloqueo de arranque del singleton

La app dejó de arrancar, sin mensaje: el log se cortaba y se quedaba colgada. Causa:
`FileService.init()` llamaba a `rebuild()`, que mira `AppServices.shared` para sacar las máquinas
SSH — y `FileService` se construye **dentro** de esa misma propiedad estática. **Pedir un `static
let` mientras se está inicializando deja a Swift bloqueado para siempre en `swift_once`**, sin
excepción ni traza. Los orígenes se montan ahora desde `AppServices.start()`.

**Regla**: nada de lo que cuelga de `AppServices.shared` puede mirar a `AppServices.shared` en su
`init`.

Copiar carpetas con progreso y arrastrar entre ubicaciones y ventanas ya están (ver
`BrunOS/Files/CLAUDE.md`).

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
- Dependencias: **SwiftTerm**, **Citadel** y **AMSMB2** (el cliente SMB, aprobada el 23-sep-2026;
  es dinámica y **necesita `embed: true`**, o la app no arranca en el iPhone),
  y ninguna más sin preguntar. **Citadel fijado a la
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
- **Un solo escritorio** (23-sep-2026; antes eran 3 espacios), con ventanas flotantes (por
  defecto) y mosaico estilo i3.
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
3. Compilar lo del 24-sep por la tarde (escrito sin Xcode) y probarlo en el iPhone.
