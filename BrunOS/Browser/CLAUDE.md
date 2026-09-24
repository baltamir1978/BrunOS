# Navegador

## Fase 3 — Navegador

**Escrita. El bloqueador de anuncios se verificó funcionando** (114.213 reglas, 3 de 3 listas
compiladas en el simulador) con las listas de antes; las de uBlock, bajadas en el iPhone, sin
compilar todavía (ver «Bloqueador» más abajo). El resto —clics sintéticos, pestañas, descargas— **no se ha probado
con una web de verdad**.

- `ClickInjector.js`: sintetiza ratón sobre la página porque **el ratón no llega solo al
  `WKWebView`**. Atraviesa shadow roots, incluidos los cerrados, gracias a
  `allowAccessingClosedShadowRoots` del mundo de contenido propio (Safari 27). **Hay que conservar
  la referencia al `WKContentWorld`**: los creados con `init(configuration:)` no se pueden
  recuperar después.
- `BrowserPane` + `BrowserChrome`: pestañas, atrás/adelante/recargar, barra de direcciones y el
  escudo del bloqueador. Todo dibujado y resuelto por geometría, sin un solo `UIButton`, porque en
  la pantalla externa no hay eventos del sistema.
- Máximo 8 pestañas vivas; las demás se descargan guardando URL y scroll. Cada `WKWebView` es un
  proceso de WebKit y pasado un punto iOS mata la app entera.
- **Buscador seleccionable** en Ajustes (`SearchEngine`): Google por defecto, y DuckDuckGo, Bing,
  Startpage y Ecosia. Antes estaba fijo en DuckDuckGo.
- **Descargas** a `Documentos/Descargas`, sin pisar ficheros: se numeran. Con `UIFileSharingEnabled`
  se ven también desde la app Archivos del iPhone.

### El fallo que dejó el bloqueador muerto

Daba `WKErrorDomain 7` con **cualquier** lista, incluso con una regla canónica válida. La pista
estaba en el `userInfo` del error, no en el `localizedDescription`, que siempre dice lo mismo:
**"Rule list lookup failed"**. No era la compilación, era **la consulta de caché previa**: cuando
una lista no está compilada todavía, `contentRuleList(forIdentifier:)` **lanza** en vez de devolver
`nil`. Al estar en el mismo `do` que la compilación, ese fallo saltaba al `catch` y no se compilaba
nunca. Ahora va en su propio `try?`.

**Lección**: ante un error de WebKit, mirar siempre `(error as NSError).userInfo`.

### Por qué las webs salían enormes

Tres cosas, y la tercera era la de verdad:

1. Faltaba el **user-agent de Safari de macOS**. `preferredContentMode = .desktop` pide la versión
   de escritorio pero **no cambia el user-agent**.
2. Aunque el user-agent sea de Mac, los sitios miran `navigator.maxTouchPoints` y `ontouchstart`,
   y si los ven sirven su interfaz táctil, con todo más grande. Se anulan con un script: en BrunOS
   el puntero **es** un ratón, así que no se engaña a nadie.
3. **El viewport valía 980 px.** Cuando una página no declara `meta viewport` —lo normal en una web
   de escritorio, y es el caso de la portada de Google— WebKit en iOS le asigna **980 px por
   defecto** y estira el resultado hasta el ancho real de la vista. En un panel de 1690 puntos eso
   es **1,72× de aumento sobre todo**. Se nota sólo en las portadas y no en las páginas sencillas,
   porque aquéllas sí suelen declarar su viewport.

Se corrige añadiendo `meta viewport` con `width=device-width` **sólo si la página no traía uno**:
pisárselo a un sitio que ya se adapta sería romperlo. Comprobado con un programa de prueba contra
google.com: `window.innerWidth` pasa de 980 a 1690.

Con el viewport bien, el zoom por defecto vuelve a 1: ya no hay nada que compensar.

### Borroso a 1,5×: WebKit no hace caso de `contentsScale` (24-sep-2026)

Bruno: Google se ve bien a 1× y borroso a 1,5×, con el zoom al 100 %. El lienzo del escritorio va
estirado con un `CGAffineTransform` y lo nuestro sale nítido porque cada capa se dibuja a más
densidad, pero **WebKit dibuja la página a la densidad de la pantalla** y el lienzo la estiraba
después. Ahora `BrowserTab.place(in:factor:)` le da a la vista la escala contraria (bounds ×
factor, `transform` 1/factor), con lo que en pantalla va 1:1, y `webView.pageZoom` = zoom de
Bruno × factor. `DesktopViewController.canvasFactor` da el factor, y `applyContentsScale` ya no
entra en los `WKWebView`.

**Comprobado en el simulador de iOS 27** con dos vistas, una normal y otra a 1,5×, sobre una
página con `width=device-width, initial-scale=1` (el viewport que pone BrunOS). Las dos dan el
mismo `innerWidth` y el mismo tamaño en pantalla, `devicePixelRatio` pasa de 3 a 4,5, y
`elementFromPoint` da lo mismo en las mismas coordenadas, así que el inyector no cambia. **Trampa**:
sin `initial-scale=1`, un `pageZoom` que desborda la vista hace que iOS encoja la página para
que quepa (`visualViewport.scale` 0,5) y el zoom no se ve.

### Intro no buscaba en Google: los eventos sintéticos no hacen nada solos (22-sep-2026)

Un evento creado con `dispatchEvent` **no es de confianza, y el navegador no ejecuta su acción
por defecto**: un Intro sintético no envía el formulario, un Retroceso no borra, una flecha no
mueve el cursor de texto. La página sí recibe el evento. Por eso `__brunos.key` en
`ClickInjector.js` dispara `keydown`/`keypress`/`keyup` y, **si la página no lo ha cancelado**,
hace a mano lo que haría el navegador: `requestSubmit()` del formulario, borrar, mover el cursor,
Tab al siguiente campo, espaciadora para bajar la página.

Trampa: **el buscador de Google es un `textarea` con `role=combobox`**. Intro en un `textarea`
mete un salto de línea, así que los que se comportan como caja de una línea (combobox,
`aria-autocomplete`, `rows=1`) se tratan como un `input`.

El texto se escribe con `execCommand('insertText')`, que genera `beforeinput` e `input` de verdad
y lo entienden React y compañía. **Comprobado con un programa de prueba en macOS** (un
`WKWebView` real con el inyector): Intro en google.com navega a `/search?q=…`, Retroceso borra y
la flecha mueve el cursor.

### Iframes de otro dominio: el reCAPTCHA no se podía pulsar (23-sep-2026)

Bruno abrió Google, salió el «no soy un robot» y la casilla no respondía: está en un iframe de
`google.com/recaptcha`, y el inyector sólo actuaba en el documento principal. **No es un límite
sin arreglo**, como decía el comentario antiguo: el inyector corre también dentro de cada iframe
(`forMainFrameOnly: false`). Cuando bajo el cursor hay un `<iframe>`, el inyector de fuera no
dispara nada: devuelve `{frame, args}` (a qué iframe y con las coordenadas ya pasadas a las suyas,
marco menos borde y relleno), y `BrowserTab.send` se lo manda al inyector de ese iframe con
`evaluateJavaScript(in: frameInfo)`. Anidados, se repite. El teclado va al último iframe pinchado.

- **Cada iframe se presenta a Swift** al cargar, por el canal `brunosFrame`, que sólo existe en el
  mundo de contenido de BrunOS; Swift guarda su `WKFrameInfo` (`FrameRegistrar`, con referencia
  débil: el controlador retiene al manejador). Se busca por el `src`, o por el sitio si el iframe
  ha navegado por dentro.
- **La primera versión reenviaba por `postMessage` con una clave, y la revisión lo tumbó**: a un
  iframe sin inyector (un `about:blank` que crea la propia página) la clave le llegaba igual, la
  página la leía y podía fabricar clics en otro iframe, como el de un pago. **Nada de este camino
  puede pasar por la página.**
- **Comprobado en un `WKWebView` de macOS** con dos servidores locales en puertos distintos (otro
  origen): el iframe se registra, un clic en (170, 155) de la página llega al botón del iframe
  como (65, 50) —su borde de 5 px incluido— y pinchar su campo y escribir mete el texto.
- **Duda que queda**: los eventos siguen siendo sintéticos (`isTrusted = false`). Puede que
  reCAPTCHA acepte el clic y luego pida el reto de las imágenes, que también es un iframe y
  también debería ir.
- **El user-agent decía Safari 18.6**, y un Safari de hace años con un motor de ahora es de lo
  que hace sospechar a Google. Ahora lleva la versión del sistema (Safari va con el mismo número
  que iOS desde la 26).

**Cookies y sesiones**: no se configura `websiteDataStore`, así que es el `default()`, que guarda
en disco. Las sesiones iniciadas se mantienen entre arranques y todas las pestañas las comparten.

**Aun así, Google pedía el aviso de cookies en cada arranque** (24-sep-2026). No se ha podido
reproducir (el aviso sólo sale en la UE); la hipótesis es que WebKit escribe las cookies a disco
cuando le parece, desde su proceso de red, y si iOS cierra la app antes se pierde lo último, que
es justo aceptar el aviso sin navegar después. `CookieVault` guarda aparte las cookies **con
caducidad** (las de sesión no) dos segundos después de cada cambio (`WKHTTPCookieStoreObserver`)
y al irse a segundo plano, en `cookies.plist` de Application Support, fuera de la copia de
iCloud; al arrancar repone las que falten **antes de la primera carga**. **Si algún día se añade
«borrar datos de sitios», hay que borrar también ese fichero**, o las volvería a poner.

### Descargas, pestañas y el botón derecho del navegador

- **Las descargas no funcionaban** por dos cosas: faltaba
  `decidePolicyFor navigationAction` con `shouldPerformDownload` (los `<a download>` y los `blob:`
  navegaban en vez de descargar), y el aviso `onDownloadChange` no lo escuchaba nadie. Ahora
  también se descarga lo que llega con `Content-Disposition: attachment`, y sale un aviso abajo
  del panel que abre la carpeta en Ficheros. Comprobado en la misma prueba de macOS.
- **Todas las pestañas compartían `WKWebViewConfiguration`**, y con ella el
  `WKUserContentController`: cada pestaña nueva volvía a meter los scripts, así que con cinco
  pestañas el inyector se cargaba cinco veces por página. Ahora cada una tiene la suya.
- **El botón derecho** sólo le llegaba a la página como `contextmenu`: el menú del sistema no sale
  nunca. BrunOS pone el suyo (abrir en pestaña nueva, descargar, copiar, guardar imagen, buscar la
  selección, bloquear en el sitio). Cmd+clic y el botón central abren el enlace en otra pestaña, y
  los `target=_blank` también.
- **Vídeo**: `allowsInlineMediaPlayback` (si no, el vídeo se va al reproductor del sistema en el
  iPhone, que está apagado), sin exigir gesto para reproducir (los clics sintéticos no cuentan
  como gesto) y `isElementFullscreenEnabled`. **YouTube funciona en el iPhone** (lo confirmó Bruno
  el 22-sep-2026); Plex, que va por el mismo camino, sin probar.

### Contraseñas: quitadas (24-sep-2026)

Había un puente a las contraseñas de iOS (`PasswordBridge`, `PasswordAutoFillView`): al pinchar un
campo de acceso, salía en el iPhone una hoja con la llave de Contraseñas. **Bruno pidió quitarlo
entero**; las escribe a mano. Además era lo que rompía el login de Reddit: con el iPhone de mando,
**la hoja tapaba el trackpad**, así que los clics de AssistiveTouch caían en ella y el teclado
físico escribía en su campo. Ni clicar ni escribir en la web.

Comprobado en un `WKWebView` de macOS contra `reddit.com/login` con el inyector: el clic llega al
campo de usuario, que está dentro de un *shadow root*, y el texto se escribe.

**Regla que queda**: con monitor, nada puede presentarse en el iPhone sin que el usuario lo pida
desde allí (el selector de carpetas sí, porque lo pide él y avisa `PhoneNotice`).

**Trampa que salió aquí y afectaba a más cosas**: con `allowAccessingClosedShadowRoots`, buscar
qué hay bajo el cursor se metía también en el shadow root **interno** de un `<input>` y devolvía su
`div`. No se reconocían los campos de texto (tampoco el «Pegar» del botón derecho). Ahora
`deepElementFromPoint` no entra en los controles nativos.

### Bloqueador: las listas de uBlock Origin, bajadas en el iPhone (24-sep-2026)

Bruno pidió todas las listas que trae uBlock y que desaparecieran los **recuadros grises** donde
iba un anuncio. **Escrito desde Linux; compila, y en el simulador compila las listas (169.903 reglas). Sin probar en el iPhone.**

- **`FilterList.catalog`**: el catálogo de uBlock (`assets/assets.json`), con sus direcciones y
  grupos. Encendidas de serie, las de uBlock (Anuncios, Privacidad, Malware, Arreglos, Arreglos
  rápidos), EasyList, EasyPrivacy, Peter Lowe, Online Malicious URL y **EasyList Spanish**. Fuera,
  «URL Tracking Protection»: sólo lleva `$removeparam`. Se pueden añadir listas por dirección.
- **Se bajan en el propio iPhone** a Application Support/Blocklists (fuera de la copia de
  iCloud), cada 4 días o con «Actualizar ahora». Los `!#include` de uBlock se resuelven al bajar
  (su lista «Anuncios» es casi todo `filters-20NN.txt`). Se acabó `Tools/fetch-blocklists.sh` y
  las listas en el bundle; `removeLegacyLists` borra del almacén las `blocklist-*` viejas. **Si
  en el Mac queda `BrunOS/Resources/Blocklists/`, se puede borrar**: ya no se lee.
- **`FilterListConverter`** traduce red (`||`, comodines, `$domain`, `$3p`, tipos con los alias
  de uBlock, `$badfilter`, `$document`/`$elemhide`/`$generichide`), ficheros hosts y la
  **ocultación** (`##`, `dominio##`, `#@#`), que antes se tiraba y es lo que quita los recuadros.
  Directivas `!#if`: es `env_safari` y no `env_mobile`. Se probó antes en Python con las listas
  reales (116.000 bloqueos, 27.000 selectores) y los selectores, uno a uno, con Chromium: **0
  inválidos** tras quitar los procedurales de uBlock y los `:has` anidados.
- **Todas las listas se convierten juntas**: `ignore-previous-rules` sólo anula reglas de su
  misma lista de WebKit, y las excepciones de «Arreglos» no servirían contra EasyList compilada
  aparte. Bloqueos en trozos de 50.000 (`brunos-filters-NN`) con **todas las excepciones detrás
  de cada trozo**, y la ocultación en `brunos-cosmetic`, aparte para que una excepción de red sin
  tipo no la anule. Selectores en grupos de 100 por regla: si uno es inválido, WebKit se salta la
  regla, no la lista. Lo compilado se reutiliza al arrancar si la firma (listas y fechas) no
  cambia.
- **`BlockerCollapse.js`** pliega lo que queda, como uBlock: las imágenes que dan `error` (y
  vuelven si luego cargan) y los iframes cuyo dominio las listas bloquean entero
  (`ContentBlocker.isBlockedHost`, preguntado por `brunosCollapse` y contestado en el marco que
  pregunta). Se apaga en Ajustes › Bloqueo. Probado en Chromium con un canal simulado.
- **Encima van las reglas propias**, compiladas aparte en `brunos-user-rules`: dominios
  bloqueados y elementos ocultos con la sintaxis de AdBlock (`dominio##selector`).
- **Lo que no entra**: scriptlets (`##+js`), procedurales (`:has-text`, `:upward`…), `$redirect`,
  `$removeparam`, `$csp`, expresiones regulares. uBlock hace más en páginas con antibloqueo.

**Lo menos seguro sin compilar**: la primera compilación en el iPhone (unos 160.000 reglas en 4
listas de WebKit; puede tardar), y si WebKit acepta todos los `resource-type` y `load-type` que
salen. Si una lista no compila, el error sale en Ajustes con el `userInfo` en el log.

### Avisos de cookies: «I Still Don't Care About Cookies» (24-sep-2026)

Lo pidió Bruno, con un icono para apagarlo por sitio en la barra del navegador. **Sin compilar
ni probar en el iPhone.**

- **`CookieNoticeBlocker`** hace lo que `activateDomain`/`doTheMagic` de la extensión: en cada
  marco, `common.css`, `embedsHandler.js` y, si el sitio (o un padre, quitando `www.`) tiene regla
  en `rules.js`, su CSS, su CSS común y su script; si no, `0_defaultClickHandler.js`.
- **La extensión es GPL-3 y BrunOS MIT: no se copia nada.** Sus ficheros se bajan de su
  repositorio (`OhMyGuus/I-Still-Dont-Care-About-Cookies`, rama `master`) a Application
  Support/CookieNotices, cada 4 días; todos o ninguno. `rules.js` es un módulo de JS: se le quita
  el `export` y se evalúa con JavaScriptCore para sacar JSON.
- Cada marco pide lo suyo al cargar (`brunosCookies`, un script de una línea al empezar el
  documento) y Swift le contesta con `evaluateJavaScript` en ese marco. Todo en **su propio mundo
  de contenido** (`brunos-cookies`), sin los canales del inyector: es código de fuera.
- **La galleta** (`BrowserChrome.drawCookie`, SF Symbols no trae) va junto al escudo: apaga el
  sitio y recarga, porque lo ya inyectado no se puede sacar. También en el clic derecho.
- Fuera: su bloqueo de red (`rules.json`), que cubren las listas de avisos de cookies del
  bloqueador. Los scripts se probaron envueltos en Chromium, sin errores.

### El contador de bloqueados: quitado

`WKContentRuleList` **no informa de cuántas peticiones detiene** — el filtrado ocurre dentro de
WebKit y no hay callback. Se podría enseñar una estimación contando peticiones desde la app, pero
sería un número inventado con pinta de dato. Se enseña sólo si el bloqueador está activo para el
sitio, que eso sí se sabe.

### Restricciones de WebKit para las reglas

Costaron un rato, y cuando algo no le gusta rechaza **la lista entera** sin decir qué regla era:

- `url-filter` tiene que ser **ASCII puro**.
- **`if-domain` y `unless-domain` no pueden ir juntos** en el mismo trigger.
- Los dominios, en minúsculas.
- `resource-type` sólo admite una lista cerrada de valores.
- Las reglas con `ignore-previous-rules` van **después** de los bloqueos.

### Favoritos, iconos y sugerencias (22-sep-2026)

Lo pidió Bruno: que se parezca lo más posible a Safari.

- **`BookmarksBar`**, bajo la de direcciones, se apaga desde Ajustes › Navegador › Favoritos. Los
  que no caben **no se encogen**: van a un menú `»` al final. Una barra con quince favoritos de
  tres letras no sirve para nada.
- **`FaviconStore`**: los iconos se piden **al propio sitio** (`<link rel=icon>` que declara la
  página, y si no `/favicon.ico`), nunca a un servicio de iconos de terceros, que sería entregarle
  a un extraño la lista entera de favoritos. Se guardan reducidos a 32 px en Application Support.
  Un icono que falta **no se vuelve a pedir en toda la sesión**: `icon(for:)` lo llama un
  `draw(_:)`, y reintentar sería una petición por fotograma. Salen también en las pestañas, en las
  sugerencias y en la página de inicio; si no hay, va un cuadrado de color estable por dominio con
  la inicial, que es mejor que un hueco.
- **`AddressSuggestions`**: la lista que cae al escribir. La primera fila es **siempre lo escrito**
  (como dirección o como búsqueda), y debajo los favoritos y el historial que encajen. La fila de
  búsqueda **no pasa por `load`**: si lo escrito parece una dirección, `load` la abriría como tal y
  elegir «Buscar» no habría servido de nada.
- **Cmd+D**, la estrella de la barra y el clic derecho llaman todos a `BrowserPane.toggleBookmark()`,
  para que el icono y el aviso no puedan decir cosas distintas.
- **Barra de progreso dentro de la cápsula** de dirección (`estimatedProgress`), recortada con la
  propia forma redondeada. Vale 1 cuando no se está cargando: si no, se quedaba a medias al
  cancelar una carga.

### Vídeo por trozos (HLS): con AVFoundation (23-sep-2026)

`HLSDownloader` baja los `.m3u8` con `AVAssetDownloadURLSession` (sesión de fondo, obligatoria) a
un `.movpkg` y lo pasa a `.mp4` con `AVAssetExportSession` en *passthrough*, sin recodificar.
**No se bajan los trozos a mano**: una lista HLS puede llevar varias calidades, audio aparte,
trozos cifrados con AES y MPEG-TS, y unir `.ts` da un fichero que el iPhone no reproduce.

- Con **Media Source Extensions** (hls.js) el `<video>` sólo enseña un `blob:`; la lista se saca
  del registro de peticiones de la página (`performance.getEntriesByType('resource')`).
- Van las cookies de la pestaña (`AVURLAssetHTTPCookiesKey`) y el user-agent; **el `Referer` no**,
  AVFoundation no deja ponerlo.
- Fuera: DRM (FairPlay), DASH (`.mpd`) y YouTube.
- **Sin probar**: en un programa de terminal del Mac la sesión de fondo no arranca, hace falta
  una app de verdad.
- **Antes de AVFoundation, `HLSDownloader.singleFile(behind:)`** (23-sep-2026, por RedGifs): si
  la cabecera y todos los trozos son rangos (`EXT-X-BYTERANGE`) de **un mismo fichero**, ese
  fichero es ya un MP4 fragmentado completo y se baja tal cual por `startDownload`, con `Referer`.
  Comprobado con la lista real de RedGifs (`api.redgifs.com/v2/gifs/<id>/hd.m3u8` → un `.m4s`
  con vídeo y audio). No se usa si hay cifrado o **audio en pista aparte** (`TYPE=AUDIO` en la
  maestra): el ejemplo fMP4 de Apple habría salido mudo.
- **El botón derecho no veía los vídeos de RedGifs** (24-sep-2026): encima del `<video>` hay
  capas (controles, la zona que recoge los clics) y `mediaAt` sólo subía por los antepasados del
  elemento bajo el cursor. Ahora `mediaElementAt` mira también `elementsFromPoint` y, al final,
  qué `<video>` contiene el punto. Y en un feed, la `.m3u8` es la del vídeo de debajo
  (`hlsListFor`: la que lleva el nombre de su cartel, `NombreDelGif-poster.jpg` ↔
  `/gifs/nombredelgif/hd.m3u8`), no la primera del registro. Comprobado en un `WKWebView` de
  macOS con un vídeo tapado por un `div`; lo del cartel, sin probar contra RedGifs.
- El inyector sube el registro de peticiones a 5000 (`setResourceTimingBufferSize`): con 250, en
  el feed de RedGifs las miniaturas lo llenaban y la `.m3u8` del vídeo no quedaba apuntada.

### Modo lectura

`readerArticle()` en el inyector es un Readability en pequeño: **el artículo es el bloque con más
texto en párrafos**, penalizando por clase o id lo que huele a navegación o comentarios. Con menos
de 600 caracteres de párrafos no se considera artículo y se dice, que es mejor que enseñar un
revoltijo. El HTML se limpia a una lista blanca de etiquetas y sólo sobreviven `href` y `src`, ya
absolutos.

La página del lector se carga **con `baseURL` de la original**: sin eso, las imágenes y los
enlaces relativos del artículo no tendrían desde dónde resolverse. `readerOrigin` guarda de dónde
salió, y cualquier navegación (`load`, atrás, adelante, recargar) sale del modo lectura, porque el
HTML del artículo no está en ningún servidor y recargarlo no significa nada.

### Descargar vídeos

- El detector (`mediaItems()`) mira **`currentSrc` primero**: es lo que el navegador está
  reproduciendo de verdad, ya resuelto entre todos los `<source>`. Luego el `src`, los `<source>`
  y los `og:video`, que muchos sitios rellenan con el fichero directo aunque el reproductor use
  otra cosa.
- **Lo que va por trozos se dice, no se esconde**: un `blob:` es memoria de la pestaña y un `.m3u8`
  o un `.mpd` son listas de segmentos. Ninguno es un fichero que guardar. Salen en el menú
  apagados y explicando por qué.
- **HLS sí**: ver «Vídeo por trozos» más abajo.
- **YouTube no entra y no va a entrar**: sirve vídeo y audio por separado (DASH) y descifra la
  firma ejecutando su propio JavaScript. Eso es yt-dlp, que es Python y se actualiza cada pocos
  días porque YouTube rompe los extractores a propósito. La salida razonable, si hace falta, es
  lanzar yt-dlp **en la máquina del tailnet** por la sesión SSH que ya existe.
- La descarga va por `startDownload` del `WKWebView`, **con `Referer` y `Origin` de la página**:
  los CDN que protegen el hotlinking (RedGifs y compañía) devuelven 403 a un mp4 pedido a pelo. El
  nombre sale del título de la página, no del `videoplayback` del servidor.
- **Progreso**: KVO sobre `WKDownload.progress`. El observador llega en cualquier hilo, así que
  sólo cruza números al actor principal, nunca el `Progress`, que no es `Sendable`. Se refresca
  **cada punto porcentual**: a cada trozo, el repintado se notaba en el cursor.
- **`DownloadCenter`** está fuera del panel: una descarga sigue viva aunque se cierre la pestaña, y
  tiene que verse desde cualquier navegador, como el ⤓ de Safari. Guarda los cancelar en un
  diccionario aparte, para que el modelo que se compara y se copia no arrastre closures.
- «Guardar como PDF» usa `WKWebView.createPDF`: lo pagina WebKit entero, no es una captura.

### Ventana de historial (Cmd+Y, 23-sep-2026)

`HistoryWindow`, como «Mostrar todo el historial» de Safari: agrupado por días, con buscador que
filtra según se escribe (por partes, como el lanzador), Intro o clic abre en la pestaña actual y
Cmd+Intro o el botón central en otra. Se borra una visita (el aspa sale al pasar el cursor, o
Cmd+⌫), la última hora, hoy o todo; «Borrar todo» pide un segundo clic. También desde el lanzador.
El icono de cada fila es el de la barra de favoritos, ahora en `FaviconStore.drawSiteIcon`.

**Sin probar en el iPhone.**

### Pestañas

Menú del clic derecho sobre una pestaña (recargar, duplicar, fijar, silenciar, cerrar, cerrar las
demás) y **Cmd+Mayús+T** para reabrir la última cerrada. De las cerradas se guarda **sólo la
dirección**: mantener vivo un `WKWebView` por si acaso es justo lo que hace que iOS mate la app.

### Fijar y silenciar pestañas (24-sep-2026)

Lo pidió Bruno, como en Safari. **Sin probar en el iPhone ni compilar** (se escribió desde Linux).

- **Fijadas**: van siempre delante, estrechas y sólo con el icono, sin aspa. Cmd+W no las cierra
  (sale un aviso), «Cerrar las demás» se las salta, y se recuerdan al arrancar
  (`SavedDesktop.Window.pinnedTabs`). Desde su menú sí se pueden cerrar.
- **Silenciar**: **WebKit no tiene un «silenciar página» público** (el de Safari, `_setPageMuted`,
  es privado). Lo hace el inyector: `muted` en cada `<video>` y `<audio>`, en todos los marcos, y
  en los que vayan apareciendo o a los que la página devuelva el volumen (`play`,
  `loadedmetadata`, `volumechange` en captura). Al quitarlo sólo recuperan el sonido los que
  silenció BrunOS (`WeakSet`). Swift lo vuelve a poner en `didCommit`, en `didFinish`, con cada
  aviso de medios y en cada iframe que se presenta. **Lo que suene por Web Audio no se calla.**
- **El altavoz** sale en la pestaña y en la cápsula de dirección cuando suena algo
  (`requestMediaPlaybackState`, preguntado cuando la página avisa de `play`/`pause`/`ended`, no con
  un temporizador) o está silenciada. Pulsarlo silencia. El aviso de medios llega ahora también de
  los iframes: un reproductor incrustado vive en el suyo.
- Cmd+Ctrl+M silencia la pestaña que se ve; «Silenciar las demás» en el menú.

### Pantalla completa de vídeo: YouTube, Plex (24-sep-2026)

Lo pidió Bruno. **Sin compilar ni probar en el iPhone**; el script, probado en Chromium (página
y un iframe de otro origen, entrar, salir y salir desde fuera).

- **La pantalla completa de WebKit no vale**: exige un gesto de verdad, y los clics y teclas de
  BrunOS son sintéticos (el botón de YouTube y su tecla F no hacían nada); y en iOS la presenta en
  una ventana suya, sin saber en qué pantalla. **`FullscreenBridge.js`** (mundo de la página, en
  todos los marcos) sustituye la API: `requestFullscreen`, `webkitRequestFullscreen`, el
  `webkitEnterFullscreen` de `<video>`, `exitFullscreen`, `document.fullscreenElement` y los
  eventos `fullscreenchange`. Estira el elemento con CSS (y quita `transform`/`filter` a sus
  antepasados, que harían el `fixed` relativo a ellos). Dentro de un iframe, pide al de fuera por
  `postMessage` que estire el iframe, hasta arriba; el de arriba avisa a Swift (`brunosFullscreen`).
- **`BrowserPane.setVideoFullScreen`**: fuera pestañas, dirección y favoritos, sin esquinas ni
  borde, y **`DesktopViewController.setVideoFullScreen`** lleva la ventana a todo el monitor por
  encima de las demás (`paneFrames`, `paneHit`, `arrangeFloating`) sin tocar el mosaico ni las
  flotantes, y esconde dock y barra **sin que asomen** (la barra del vídeo está abajo).
- **Sólo justo después de un clic o una tecla** (5 s, `lastUserInput`): si no, cualquier web
  podría adueñarse del monitor.
- **Salir**: Esc, Ctrl+Cmd+F, el botón de la propia página, cambiar de pestaña, navegar, cerrar o
  minimizar la ventana.

### Botón de historial e indicador de zoom (24-sep-2026)

- El historial tiene botón en la barra, junto a atrás, adelante y recargar (Bruno no lo quería
  sólo con Cmd+Y).
- Cmd + / − / 0 enseñan «125 %» en el centro de la página durante un segundo, como Safari.

### RedGifs dentro de Reddit (24-sep-2026, noche)

«Descargar vídeo» no salía: Reddit mete el reproductor de RedGifs en un iframe de otro dominio y
`mediaAt` sólo miraba la página principal. Ahora, si bajo el cursor hay un iframe, devuelve
`{frame, args}` como los clics, y `BrowserTab.media(at:)` le pregunta al inyector de ese iframe
(hasta 6 niveles). Cada vídeo trae `page` (la dirección de la página donde se vio), y la descarga
usa ésa como `Referer`: con la de Reddit, el CDN de RedGifs lo niega. **Comprobado en macOS** con
un iframe en otro puerto: el punto llega bien descontado el margen y el borde, y el `Referer` es el
del iframe. **Sin probar contra Reddit.**

### YouTube a pantalla completa ponía la web entera (24-sep-2026, noche)

**YouTube pide la pantalla completa para la página entera** (`<html>`) y luego no recoloca el
vídeo: con la imitación de `FullscreenBridge.js`, se estiraba la web y el vídeo se quedaba donde
estaba. Comprobado con YouTube de verdad en un `WKWebView` de macOS con el propio script (vídeo
959×720 en una ventana de 1400×900 tras pulsar el botón). Ahora `fullscreenTarget`: si lo
pedido es la página, o algo mucho más grande que su vídeo, se estira el **reproductor** (el
antepasado más alto del vídeo más grande que tiene su mismo tamaño); dentro, cada contenedor del
vídeo va en `position: absolute; inset: 0` y el vídeo con `object-fit: contain`, y se lanza
`resize` para que la página vuelva a medir. Resultado en la misma prueba: vídeo 1400×900, los
controles de YouTube abajo a todo lo ancho, y al salir todo vuelve a su sitio (captura vista).
**Trampa**: `height: 100%` en los contenedores no vale; YouTube tiene uno con relleno por
proporción y el vídeo salía de 1950 de alto.
