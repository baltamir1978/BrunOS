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
  como gesto) y `isElementFullscreenEnabled`. **Plex y compañía sin probar.**

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
