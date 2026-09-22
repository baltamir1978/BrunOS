# Navegador

## Fase 3 — Navegador

**Escrita. El bloqueador de anuncios está verificado funcionando** (114.213 reglas, 3 de 3 listas
compiladas en el simulador). El resto —clics sintéticos, pestañas, descargas— **no se ha probado
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

### Contraseñas: las de iOS, a través del iPhone (22-sep-2026)

Bruno eligió las contraseñas de iOS, las de Safari, en vez de un gestor propio. El autorrelleno de
iOS sólo se ofrece en el teclado del sistema, sobre un campo nativo y con el dedo, así que hay un
puente (`PasswordBridge`): al pinchar en la página un campo de usuario o de contraseña, se abre en
el iPhone `PasswordAutoFillView`, dos campos con `textContentType` de usuario y contraseña, donde
iOS pone la llave de Contraseñas. Lo elegido se pasa a la página con `__brunos.fillLogin` y **no se
guarda en ningún sitio**.

- El autorrelleno escribe la contraseña de golpe y a mano va letra a letra: un salto de más de un
  carácter se manda solo, sin pulsar Rellenar.
- Mientras la hoja está abierta, el teclado físico escribe en ella (es el primer respondedor), así
  que Esc tiene que cerrarla desde la propia hoja. Al cerrarse se devuelve el teclado al
  controlador raíz.
- Si se cancela, en esa web no se vuelve a ofrecer hasta que se cargue otra página.
- **Comprobado en un `WKWebView` de macOS**: se detectan los campos, también el de usuario sin
  `autocomplete`, y se rellenan con comillas incluidas. **Sin probar en el iPhone**, que es donde
  tiene que salir la llave de Contraseñas.

**Trampa que salió aquí y afectaba a más cosas**: con `allowAccessingClosedShadowRoots`, buscar
qué hay bajo el cursor se metía también en el shadow root **interno** de un `<input>` y devolvía su
`div`. No se reconocían los campos de texto (tampoco el «Pegar» del botón derecho). Ahora
`deepElementFromPoint` no entra en los controles nativos.

### Bloqueador editable

`Tools/fetch-blocklists.sh` genera ahora **una lista por fuente** (`blocklist-easylist-NN`,
`blocklist-easyprivacy-NN`) y un `manifest-blocklists.json` con cuántas reglas lleva cada una, para
poder apagarlas por separado sin leer megas de JSON al arrancar. Encima van **reglas propias**,
compiladas aparte en `brunos-user-rules`: dominios bloqueados y elementos ocultos con la sintaxis
de AdBlock (`dominio##selector`). El formato se comprobó compilándolo con WebKit en macOS.

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

### Pestañas

Menú del clic derecho sobre una pestaña (recargar, duplicar, cerrar, cerrar las demás) y
**Cmd+Mayús+T** para reabrir la última cerrada. De las cerradas se guarda **sólo la dirección**:
mantener vivo un `WKWebView` por si acaso es justo lo que hace que iOS mate la app.
