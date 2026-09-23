// Inyección de ratón en la página.
//
// POR QUÉ EXISTE ESTO
//
// El ratón de BrunOS no llega de forma nativa al WKWebView: la pantalla externa
// no es interactiva y el cursor lo dibuja la app. Así que los clics, el hover y
// la rueda se sintetizan aquí, a partir de coordenadas que manda Swift.
//
// IFRAMES DE OTRO DOMINIO
//
// La política del mismo origen impide alcanzar su DOM desde la página, pero
// este inyector corre también **dentro** de cada iframe (`forMainFrameOnly:
// false`). Cuando lo que hay bajo el cursor es un iframe, en vez de disparar el
// evento se devuelve a Swift a qué iframe va y con qué coordenadas, ya pasadas
// a las suyas, y Swift se lo manda al inyector de ese iframe. Es lo que hace
// pulsable la casilla de reCAPTCHA, los avisos de cookies o las pasarelas de
// pago. Ver `forwardToFrame` y `BrowserTab.send`.

'use strict';

// El registro de peticiones de la página guarda 250 por defecto y, lleno, deja
// de apuntar: en una página con muchas miniaturas (el feed de RedGifs) la lista
// `.m3u8` del vídeo llegaba tarde y no quedaba rastro de ella. Ver `mediaItems`.
try {
    performance.setResourceTimingBufferSize(5000);
} catch (error) {}

const BrunOS = {
    lastHovered: null,
    lastDownTarget: null,
    /// El iframe donde se pinchó por última vez: el teclado va a él.
    focusedFrame: null,
};

/// Busca el elemento más profundo en un punto, atravesando shadow roots.
///
/// `document.elementFromPoint` se detiene en el anfitrión de un shadow root y
/// devuelve el componente entero en vez del botón de dentro. Hay que ir
/// bajando raíz por raíz.
///
/// En el mundo de contenido que crea BrunOS, `allowAccessingClosedShadowRoots`
/// está activado, así que `shadowRoot` responde también en los cerrados, a los
/// que normalmente no se llega de ninguna manera.
function deepElementFromPoint(x, y) {
    let element = document.elementFromPoint(x, y);
    if (!element) return null;

    let guard = 0;
    while (element.shadowRoot && !NATIVE_CONTROLS.has(element.tagName.toLowerCase()) && guard++ < 20) {
        const inner = element.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === element) break;
        element = inner;
    }
    return element;
}

/// Los controles nativos tienen su propio shadow root **del navegador** por
/// dentro. Con `allowAccessingClosedShadowRoots` se llega también a él, y
/// entonces bajo el cursor salía el `div` interno de un `<input>` en vez del
/// campo: no se reconocían los campos de texto ni los de contraseña. En ésos
/// no se entra.
const NATIVE_CONTROLS = new Set(['input', 'textarea', 'select', 'video', 'audio', 'meter', 'progress']);

function makeMouseInit(x, y, button, modifiers) {
    return {
        bubbles: true,
        cancelable: true,
        composed: true,
        view: window,
        clientX: x,
        clientY: y,
        screenX: x,
        screenY: y,
        button: button,
        buttons: button === 0 ? 1 : (button === 2 ? 2 : 4),
        ctrlKey: !!(modifiers && modifiers.ctrl),
        altKey: !!(modifiers && modifiers.alt),
        shiftKey: !!(modifiers && modifiers.shift),
        metaKey: !!(modifiers && modifiers.meta),
    };
}

function makePointerInit(base) {
    return Object.assign({}, base, {
        pointerId: 1,
        pointerType: 'mouse',
        isPrimary: true,
    });
}

/// Un clic completo, en el orden que espera la web.
///
/// El orden importa: hay bibliotecas que escuchan `pointerdown` y otras que
/// sólo miran `click`, y algunas se confunden si falta alguno del medio. Este
/// es el que dispara un navegador de verdad.
function click(x, y, button, modifiers) {
    const target = deepElementFromPoint(x, y);
    if (!target) return false;

    if (isFrame(target)) {
        BrunOS.focusedFrame = target;
        return forwardToFrame(target, x, y, [button, modifiers]);
    }
    BrunOS.focusedFrame = null;

    const base = makeMouseInit(x, y, button, modifiers);
    const pointer = makePointerInit(base);

    target.dispatchEvent(new PointerEvent('pointerdown', pointer));
    target.dispatchEvent(new MouseEvent('mousedown', base));

    focusIfEditable(target);

    target.dispatchEvent(new PointerEvent('pointerup', pointer));
    target.dispatchEvent(new MouseEvent('mouseup', base));

    if (button === 0) {
        target.dispatchEvent(new MouseEvent('click', base));
    } else if (button === 2) {
        target.dispatchEvent(new MouseEvent('contextmenu', base));
    }

    BrunOS.lastDownTarget = target;
    return true;
}

/// Lleva el foco al elemento editable correcto.
///
/// Si se pincha dentro de un campo, el foco tiene que acabar en el campo, no en
/// el `div` decorativo que lo envuelve. Sin esto, el teclado escribe en el
/// vacío. Se sube por los ancestros hasta encontrar algo que acepte foco.
function focusIfEditable(element) {
    let node = element;
    let guard = 0;
    while (node && guard++ < 10) {
        const tag = node.tagName ? node.tagName.toLowerCase() : '';
        if (tag === 'input' || tag === 'textarea' || tag === 'select' || node.isContentEditable) {
            node.focus();
            return;
        }
        node = node.parentElement || (node.getRootNode() || {}).host;
    }

    // Si no hay campo, se le da el foco igualmente al elemento pinchado cuando
    // lo admita: así funcionan los atajos de teclado de la página.
    if (typeof element.focus === 'function') {
        element.focus({ preventScroll: true });
    }
}

/// Movimiento del ratón, con `mouseover` y `mouseout` cuando cambia el elemento.
///
/// Sin esto no funcionan los menús desplegables ni nada que reaccione al pasar
/// por encima. La frecuencia la limita Swift, no esta función.
function hover(x, y) {
    const target = deepElementFromPoint(x, y);
    if (!target) return false;

    const base = makeMouseInit(x, y, 0, null);
    base.buttons = 0;

    // Al entrar en un iframe, lo de fuera tiene que enterarse de que el ratón
    // se ha ido: si no, un menú desplegable junto a un anuncio se quedaba
    // abierto para siempre.
    if (isFrame(target)) {
        leaveHovered(base);
        return forwardToFrame(target, x, y, []);
    }

    if (BrunOS.lastHovered !== target) {
        leaveHovered(base);
        target.dispatchEvent(new MouseEvent('mouseover', base));
        target.dispatchEvent(new MouseEvent('mouseenter', base));
        BrunOS.lastHovered = target;
    }

    target.dispatchEvent(new PointerEvent('pointermove', makePointerInit(base)));
    target.dispatchEvent(new MouseEvent('mousemove', base));
    return true;
}

function leaveHovered(base) {
    if (!BrunOS.lastHovered) return;
    BrunOS.lastHovered.dispatchEvent(new MouseEvent('mouseout', base));
    BrunOS.lastHovered.dispatchEvent(new MouseEvent('mouseleave', base));
    BrunOS.lastHovered = null;
}

/// Rueda del ratón.
///
/// Se busca el ancestro que de verdad pueda desplazarse y se le mueve a él. Ir
/// directo a `window.scrollBy` fallaría en cualquier página con paneles
/// internos, que son casi todas las modernas.
function wheel(x, y, deltaX, deltaY) {
    const target = deepElementFromPoint(x, y) || document.body;
    if (isFrame(target)) return forwardToFrame(target, x, y, [deltaX, deltaY]);
    const scrollable = findScrollable(target, deltaY);

    if (scrollable === document.scrollingElement || !scrollable) {
        window.scrollBy(deltaX, deltaY);
    } else {
        scrollable.scrollTop += deltaY;
        scrollable.scrollLeft += deltaX;
    }

    target.dispatchEvent(new WheelEvent('wheel', {
        bubbles: true,
        cancelable: true,
        composed: true,
        deltaX: deltaX,
        deltaY: deltaY,
        clientX: x,
        clientY: y,
    }));
    return true;
}

function findScrollable(element, deltaY) {
    let node = element;
    let guard = 0;
    while (node && node !== document.body && guard++ < 30) {
        const style = window.getComputedStyle(node);
        const overflow = style.overflowY;
        const canScroll = (overflow === 'auto' || overflow === 'scroll' || overflow === 'overlay')
            && node.scrollHeight > node.clientHeight;
        if (canScroll) {
            const atTop = node.scrollTop <= 0;
            const atBottom = node.scrollTop + node.clientHeight >= node.scrollHeight - 1;
            // Si ya está al tope en la dirección que se pide, se deja que el
            // desplazamiento siga hacia arriba, como hace un navegador.
            if (!((deltaY < 0 && atTop) || (deltaY > 0 && atBottom))) {
                return node;
            }
        }
        node = node.parentElement || (node.getRootNode() || {}).host;
    }
    return document.scrollingElement;
}

/// Qué hay bajo el cursor, para el menú contextual y para el cursor de la app.
function describe(x, y) {
    const target = deepElementFromPoint(x, y);
    if (!target) return null;

    let link = null;
    let node = target;
    let guard = 0;
    while (node && guard++ < 10) {
        if (node.tagName && node.tagName.toLowerCase() === 'a' && node.href) {
            link = node.href;
            break;
        }
        node = node.parentElement || (node.getRootNode() || {}).host;
    }

    const tag = target.tagName ? target.tagName.toLowerCase() : '';
    const editable = tag === 'input' || tag === 'textarea' || target.isContentEditable;
    const selection = String(window.getSelection() || '').trim();

    return {
        login: loginRole(target),
        selection: selection.length > 0 ? selection.slice(0, 500) : null,
        tag: tag,
        link: link,
        image: tag === 'img' ? target.src : null,
        editable: editable,
        // Para que la app pueda cambiar la forma del cursor, como un navegador.
        cursor: window.getComputedStyle(target).cursor,
    };
}

/// Los medios de la página que se pueden descargar.
///
/// **No vale con `video.src`.** Un reproductor moderno casi nunca lo usa: mete
/// `<source>` dentro del `<video>`, o monta el vídeo por trozos con Media
/// Source Extensions y entonces `src` es un `blob:`, que fuera de la página no
/// significa nada. Se recogen las tres cosas y es la app quien decide: lo
/// directo se descarga, y de lo demás se dice por qué no.
///
/// `currentSrc` va primero porque es lo que el navegador **está** reproduciendo
/// de verdad, ya resuelto entre todos los `<source>` disponibles.
function mediaItems() {
    const found = [];
    const seen = new Set();

    function add(raw, element, kind) {
        if (!raw) return;
        let url;
        try {
            url = new URL(raw, location.href).href;
        } catch (error) {
            return;
        }
        if (seen.has(url)) return;
        seen.add(url);

        const path = url.split('?')[0].split('#')[0];
        const dot = path.lastIndexOf('.');
        const extension = dot > path.lastIndexOf('/') ? path.slice(dot + 1).toLowerCase() : '';

        found.push({
            url: url,
            kind: kind,
            extension: extension,
            // Un `blob:` es memoria de la pestaña y un `.m3u8` es una lista de
            // trozos, no un fichero: ninguno de los dos se puede guardar tal
            // cual, y conviene decirlo en vez de fallar luego.
            stream: url.startsWith('blob:') || extension === 'm3u8' || extension === 'mpd',
            // HLS sí se puede bajar: lo hace AVFoundation (`HLSDownloader`).
            hls: extension === 'm3u8',
            width: element && element.videoWidth ? element.videoWidth : 0,
            height: element && element.videoHeight ? element.videoHeight : 0,
            duration: element && isFinite(element.duration) ? Math.round(element.duration) : 0,
            title: document.title || '',
        });
    }

    for (const element of document.querySelectorAll('video, audio')) {
        const kind = element.tagName.toLowerCase() === 'audio' ? 'audio' : 'video';
        add(element.currentSrc, element, kind);
        add(element.getAttribute('src'), element, kind);
        for (const source of element.querySelectorAll('source')) {
            add(source.getAttribute('src'), element, kind);
        }
    }

    // Un reproductor con Media Source Extensions (hls.js y compañía) sólo deja
    // ver un `blob:`, pero la lista `.m3u8` la ha tenido que pedir: está en el
    // registro de peticiones de la página. La maestra suele ser la primera.
    if (found.some(function (item) { return item.url.startsWith('blob:'); })) {
        const video = document.querySelector('video');
        for (const entry of performance.getEntriesByType('resource')) {
            if (/\.m3u8(\?|#|$)/i.test(entry.name)) {
                add(entry.name, video, 'video');
                break;
            }
        }
    }

    // Lo que la página declara para las redes sociales: muchos sitios ponen
    // ahí el fichero directo aunque el reproductor use otra cosa.
    for (const meta of document.querySelectorAll('meta[property="og:video"], meta[property="og:video:url"], meta[property="og:video:secure_url"]')) {
        add(meta.getAttribute('content'), null, 'video');
    }

    return found;
}

/// El medio que hay bajo el cursor, para «Descargar vídeo» del clic derecho.
function mediaAt(x, y) {
    let node = deepElementFromPoint(x, y);
    let guard = 0;
    while (node && guard++ < 10) {
        const tag = node.tagName ? node.tagName.toLowerCase() : '';
        if (tag === 'video' || tag === 'audio') {
            const items = mediaItems();
            const own = new Set();
            if (node.currentSrc) own.add(node.currentSrc);
            for (const item of items) {
                if (!own.has(item.url)) continue;
                // Si lo que suena es un `blob:`, vale más su lista HLS, que sí
                // se puede guardar.
                if (item.url.startsWith('blob:')) {
                    const hls = items.find(function (other) { return other.hls; });
                    if (hls) return hls;
                }
                return item;
            }
            return items.length > 0 ? items[0] : null;
        }
        node = node.parentElement || (node.getRootNode() || {}).host;
    }
    return null;
}

/// Extrae el artículo de la página, para el modo lectura.
///
/// Es un Readability en pequeño, con la idea de siempre: **el artículo es el
/// bloque que más texto tiene en párrafos**. Se puntúa cada candidato por la
/// longitud de sus `<p>`, se penaliza lo que huele a navegación o comentarios
/// por su clase o su id, y se devuelve el ganador ya limpio.
///
/// No se intenta acertar en todas las webs: cuando no hay un bloque claro se
/// devuelve `null` y la app lo dice, que es mejor que enseñar un revoltijo.
function readerArticle() {
    const BAD = /(^|[-_\s])(nav|menu|header|footer|sidebar|comment|share|related|promo|advert|social|newsletter|cookie|breadcrumb)([-_\s]|$)/i;
    const KEEP = new Set([
        'P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'UL', 'OL', 'LI', 'BLOCKQUOTE',
        'PRE', 'CODE', 'FIGURE', 'FIGCAPTION', 'IMG', 'A', 'EM', 'STRONG', 'B',
        'I', 'BR', 'HR', 'TABLE', 'THEAD', 'TBODY', 'TR', 'TD', 'TH', 'SPAN',
    ]);

    function textLength(node) {
        let total = 0;
        for (const paragraph of node.querySelectorAll('p, li')) {
            const text = (paragraph.innerText || '').trim();
            // Los párrafos de una línea suelen ser pies, créditos o botones.
            if (text.length > 40) total += text.length;
        }
        return total;
    }

    let best = null;
    let bestScore = 0;
    const candidates = document.querySelectorAll('article, main, [role=main], div, section');
    for (const candidate of candidates) {
        const signature = (candidate.className || '') + ' ' + (candidate.id || '');
        if (typeof signature === 'string' && BAD.test(signature)) continue;
        let score = textLength(candidate);
        if (candidate.tagName === 'ARTICLE') score *= 1.4;
        if (score > bestScore) {
            bestScore = score;
            best = candidate;
        }
    }

    // Menos de esto no es un artículo: es una portada, un panel o un buscador.
    if (!best || bestScore < 600) return null;

    const copy = best.cloneNode(true);
    // Fuera lo que no es el texto: guiones, estilos, formularios y todo lo que
    // la página use para lo suyo.
    for (const node of copy.querySelectorAll('*')) {
        if (!KEEP.has(node.tagName)) {
            node.replaceWith(...node.childNodes);
            continue;
        }
        for (const attribute of Array.from(node.attributes)) {
            const name = attribute.name.toLowerCase();
            const allowed = (node.tagName === 'A' && name === 'href')
                || (node.tagName === 'IMG' && (name === 'src' || name === 'alt'));
            if (!allowed) node.removeAttribute(attribute.name);
        }
        if (node.tagName === 'IMG' && node.getAttribute('src')) {
            try {
                node.setAttribute('src', new URL(node.getAttribute('src'), location.href).href);
            } catch (error) {
                node.remove();
            }
        }
        if (node.tagName === 'A' && node.getAttribute('href')) {
            try {
                node.setAttribute('href', new URL(node.getAttribute('href'), location.href).href);
            } catch (error) {}
        }
    }

    const heading = document.querySelector('h1');
    const author = document.querySelector('[rel=author], .byline, .author, [itemprop=author]');
    return {
        title: (heading && heading.innerText.trim()) || document.title || '',
        byline: author ? (author.innerText || '').trim().slice(0, 120) : '',
        html: copy.innerHTML,
    };
}

/// El icono del sitio que declara la página, para la barra de favoritos.
function iconURL() {
    const links = document.querySelectorAll('link[rel~="icon" i]');
    let best = null;
    let bestSize = -1;
    for (const link of links) {
        const href = link.getAttribute('href');
        if (!href) continue;
        const sizes = (link.getAttribute('sizes') || '').split('x')[0];
        const size = parseInt(sizes, 10) || 0;
        // El más grande que no sea enorme: escalar hacia abajo se ve bien,
        // hacia arriba no.
        if (size > bestSize && size <= 256) {
            bestSize = size;
            best = href;
        } else if (best === null) {
            best = href;
        }
    }
    if (!best) return null;
    try {
        return new URL(best, location.href).href;
    } catch (error) {
        return null;
    }
}

/// Escribe texto en el elemento con foco.
///
/// Primero con `execCommand('insertText')`, que es lo que hace el propio
/// navegador al teclear: genera `beforeinput` e `input` de verdad, respeta el
/// deshacer y lo entienden React y compañía, que vigilan el valor a su manera.
/// Si el campo no lo admite, se escribe el valor a mano y se avisa con `input`.
function insertText(text) {
    if (focusedFrameAlive()) return { frame: frameTarget(BrunOS.focusedFrame), args: [text] };
    const active = deepActiveElement();
    if (!active) return false;

    if (active.isContentEditable) {
        document.execCommand('insertText', false, text);
        return true;
    }

    if (!isTextField(active)) return false;

    if (document.execCommand('insertText', false, text)) return true;

    const start = active.selectionStart ?? active.value.length;
    const end = active.selectionEnd ?? active.value.length;
    active.value = active.value.slice(0, start) + text + active.value.slice(end);
    const caret = start + text.length;
    try { active.setSelectionRange(caret, caret); } catch (error) {}
    active.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    return true;
}

/// El elemento con foco, también dentro de un shadow root.
function deepActiveElement() {
    let active = document.activeElement;
    let guard = 0;
    while (active && active.shadowRoot && active.shadowRoot.activeElement && guard++ < 20) {
        active = active.shadowRoot.activeElement;
    }
    return active;
}

const TEXT_INPUT_TYPES = ['text', 'search', 'email', 'url', 'tel', 'password', 'number', ''];

function isTextField(element) {
    if (!element || !element.tagName) return false;
    const tag = element.tagName.toLowerCase();
    if (tag === 'textarea') return true;
    return tag === 'input' && TEXT_INPUT_TYPES.includes((element.getAttribute('type') || '').toLowerCase());
}

function isEditable(element) {
    return isTextField(element) || (element && element.isContentEditable);
}

/// Un `textarea` que en realidad es una caja de búsqueda de una línea.
///
/// **Google lo hace así**: su buscador es un `textarea` con rol de combobox.
/// Intro ahí tiene que buscar, no meter un salto de línea.
function behavesAsSingleLine(element) {
    if (!element || element.tagName.toLowerCase() !== 'textarea') return false;
    return element.getAttribute('role') === 'combobox'
        || element.hasAttribute('aria-autocomplete')
        || element.getAttribute('rows') === '1';
}

// Códigos heredados. Mucha web sigue mirando `keyCode` en vez de `key`.
const KEY_CODES = {
    Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, ' ': 32,
    ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40,
    PageUp: 33, PageDown: 34, Home: 36, End: 35,
};

function keyCodeFor(key) {
    if (key in KEY_CODES) return KEY_CODES[key];
    if (key.length === 1) return key.toUpperCase().charCodeAt(0);
    return 0;
}

function codeFor(key) {
    if (key === ' ') return 'Space';
    if (/^[a-z]$/i.test(key)) return 'Key' + key.toUpperCase();
    if (/^[0-9]$/.test(key)) return 'Digit' + key;
    return key;
}

function keyEvent(type, key, modifiers) {
    const keyCode = keyCodeFor(key);
    return new KeyboardEvent(type, {
        key: key,
        code: codeFor(key),
        keyCode: keyCode,
        which: keyCode,
        charCode: type === 'keypress' ? keyCode : 0,
        ctrlKey: !!(modifiers && modifiers.ctrl),
        altKey: !!(modifiers && modifiers.alt),
        shiftKey: !!(modifiers && modifiers.shift),
        metaKey: !!(modifiers && modifiers.meta),
        bubbles: true,
        cancelable: true,
        composed: true,
        view: window,
    });
}

/// Una tecla completa: `keydown`, `keypress` si toca, la acción y `keyup`.
///
/// **POR QUÉ HAY QUE HACER LA ACCIÓN A MANO.** Un evento sintético, por
/// definición, no es de confianza, y el navegador **no ejecuta su acción por
/// defecto**: un Intro sintético no envía el formulario y un Retroceso
/// sintético no borra nada. La página sí recibe el evento, así que si ella se
/// encarga —y lo cancela con `preventDefault`— no se hace nada más. Si no, se
/// hace aquí lo que habría hecho el navegador.
///
/// `text` es el carácter que se escribe, si la tecla escribe alguno.
function key(name, modifiers, text) {
    if (focusedFrameAlive()) return { frame: frameTarget(BrunOS.focusedFrame), args: [name, modifiers, text] };
    const target = deepActiveElement() || document.body;

    const down = keyEvent('keydown', name, modifiers);
    target.dispatchEvent(down);
    let prevented = down.defaultPrevented;

    // `keypress` sólo existe para lo que escribe, e Intro cuenta.
    if (!prevented && (text || name === 'Enter')) {
        const press = keyEvent('keypress', name, modifiers);
        target.dispatchEvent(press);
        prevented = press.defaultPrevented;
    }

    if (!prevented) {
        defaultAction(name, target, modifiers, text);
    }

    target.dispatchEvent(keyEvent('keyup', name, modifiers));
    return true;
}

function defaultAction(name, target, modifiers, text) {
    const shift = !!(modifiers && modifiers.shift);
    const editable = isEditable(target);

    if (text) {
        if (editable) {
            insertText(text);
        } else if (text === ' ') {
            // La espaciadora fuera de un campo baja una pantalla.
            window.scrollBy(0, (shift ? -1 : 1) * window.innerHeight * 0.85);
        }
        return;
    }

    switch (name) {
    case 'Enter':
        return enter(target, shift);

    case 'Backspace':
    case 'Delete':
        if (!editable) return;
        if (!document.execCommand(name === 'Delete' ? 'forwardDelete' : 'delete')) {
            deleteByHand(target, name === 'Delete');
        }
        return;

    case 'ArrowLeft':
    case 'ArrowRight':
        if (isTextField(target)) {
            moveCaret(target, name === 'ArrowLeft' ? -1 : 1, shift);
        } else if (target.isContentEditable) {
            window.getSelection().modify(shift ? 'extend' : 'move',
                name === 'ArrowLeft' ? 'backward' : 'forward', 'character');
        } else {
            window.scrollBy(name === 'ArrowLeft' ? -60 : 60, 0);
        }
        return;

    case 'ArrowUp':
    case 'ArrowDown':
        if (target.isContentEditable) {
            window.getSelection().modify(shift ? 'extend' : 'move',
                name === 'ArrowUp' ? 'backward' : 'forward', 'line');
        } else if (!editable) {
            window.scrollBy(0, name === 'ArrowUp' ? -60 : 60);
        }
        return;

    case 'PageUp':
    case 'PageDown':
        window.scrollBy(0, (name === 'PageUp' ? -1 : 1) * window.innerHeight * 0.85);
        return;

    case 'Home':
    case 'End':
        if (editable) return;
        window.scrollTo(0, name === 'Home' ? 0 : document.documentElement.scrollHeight);
        return;

    case 'Tab':
        return moveFocus(target, shift ? -1 : 1);
    }
}

/// Lo que haría Intro en cada sitio.
function enter(target, shift) {
    const tag = target.tagName ? target.tagName.toLowerCase() : '';

    if (tag === 'textarea' && (shift || !behavesAsSingleLine(target))) {
        insertText('\n');
        return;
    }
    if (target.isContentEditable) {
        document.execCommand(shift ? 'insertLineBreak' : 'insertParagraph');
        return;
    }
    if (isTextField(target)) {
        const form = target.form || target.closest('form');
        if (!form) return;
        // `requestSubmit` pasa por la validación y por los `submit` de la
        // página, como un envío de verdad; `submit` a pelo se los salta.
        try {
            form.requestSubmit();
        } catch (error) {
            form.submit();
        }
        return;
    }
    // Un enlace o un botón con foco se pulsan con Intro.
    if (tag === 'a' || tag === 'button' || target.getAttribute('role') === 'button') {
        target.click();
    }
}

function deleteByHand(field, forward) {
    if (!isTextField(field)) return;
    let start = field.selectionStart ?? field.value.length;
    let end = field.selectionEnd ?? field.value.length;
    if (start === end) {
        if (forward) end = Math.min(field.value.length, end + 1);
        else start = Math.max(0, start - 1);
    }
    field.value = field.value.slice(0, start) + field.value.slice(end);
    try { field.setSelectionRange(start, start); } catch (error) {}
    field.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
}

function moveCaret(field, delta, extend) {
    try {
        const start = field.selectionStart ?? 0;
        const end = field.selectionEnd ?? 0;
        if (extend) {
            field.setSelectionRange(start, Math.max(0, Math.min(field.value.length, end + delta)));
            return;
        }
        // Con texto seleccionado, la flecha colapsa hacia ese lado, como en
        // cualquier campo; sin selección, mueve un carácter.
        const position = start !== end
            ? (delta < 0 ? start : end)
            : Math.max(0, Math.min(field.value.length, start + delta));
        field.setSelectionRange(position, position);
    } catch (error) {
        // Los `input type=email` y `number` no admiten selección.
    }
}

/// Tab: al siguiente elemento que acepte foco, en orden de documento.
function moveFocus(current, direction) {
    const selector = 'a[href], button, input, select, textarea, [tabindex], [contenteditable="true"]';
    const all = Array.from(document.querySelectorAll(selector)).filter(element =>
        !element.disabled
        && element.tabIndex >= 0
        && element.offsetParent !== null
    );
    if (all.length === 0) return;
    const index = all.indexOf(current);
    const next = all[(index + direction + all.length) % all.length];
    next.focus();
    if (isTextField(next)) {
        try { next.select(); } catch (error) {}
    }
}

// INICIO DE SESIÓN
//
// Para el autorrelleno con las contraseñas de iOS: se detecta que se ha
// pinchado un campo de usuario o de contraseña, y luego se rellenan los dos.

/// 'password', 'username' o null según el campo.
function loginRole(element) {
    if (!element || !element.tagName || element.tagName.toLowerCase() !== 'input') return null;
    const type = (element.getAttribute('type') || '').toLowerCase();
    if (type === 'password') return 'password';
    const autocomplete = (element.getAttribute('autocomplete') || '').toLowerCase();
    if (autocomplete.includes('username') || autocomplete === 'email') return 'username';
    // Un campo de texto o de correo justo antes de uno de contraseña, en el
    // mismo formulario, es el del usuario aunque no lo diga.
    if (type === '' || type === 'text' || type === 'email') {
        return findPasswordField(element) ? 'username' : null;
    }
    return null;
}

function findPasswordField(near) {
    const scope = (near && (near.form || near.closest('form'))) || document;
    return Array.from(scope.querySelectorAll('input[type=password]'))
        .find(field => !field.disabled && field.offsetParent !== null) || null;
}

function findUsernameField(password) {
    const scope = (password && (password.form || password.closest('form'))) || document;
    const inputs = Array.from(scope.querySelectorAll('input'))
        .filter(field => !field.disabled && field.offsetParent !== null);
    const explicit = inputs.find(field => {
        const autocomplete = (field.getAttribute('autocomplete') || '').toLowerCase();
        return autocomplete.includes('username') || autocomplete === 'email';
    });
    if (explicit) return explicit;
    // Si no, el último campo de texto antes de la contraseña.
    const index = inputs.indexOf(password);
    const before = (index >= 0 ? inputs.slice(0, index) : inputs).reverse();
    return before.find(field => {
        const type = (field.getAttribute('type') || '').toLowerCase();
        return type === '' || type === 'text' || type === 'email';
    }) || null;
}

/// Escribe en un campo como si se tecleara: con `execCommand`, que genera los
/// eventos que esperan React y compañía.
function setFieldValue(field, value) {
    if (!field || value == null) return;
    field.focus();
    try { field.select(); } catch (error) {}
    if (!document.execCommand('insertText', false, value)) {
        field.value = value;
        field.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
    }
    field.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
}

/// Rellena el formulario de inicio de sesión que tiene el foco o el primero
/// que haya. Si el usuario viene vacío, sólo la contraseña (hay webs que piden
/// una cosa en cada paso).
function fillLogin(username, password) {
    const active = deepActiveElement();
    const passwordField = (active && (active.getAttribute('type') || '').toLowerCase() === 'password')
        ? active
        : findPasswordField(active);
    const usernameField = passwordField ? findUsernameField(passwordField)
        : (loginRole(active) === 'username' ? active : null);
    if (username && usernameField) setFieldValue(usernameField, username);
    if (password && passwordField) setFieldValue(passwordField, password);
    if (passwordField) passwordField.focus();
    return !!(usernameField || passwordField);
}

// MARK: iframes

function isFrame(element) {
    const tag = element.tagName ? element.tagName.toLowerCase() : '';
    return tag === 'iframe' || tag === 'frame';
}

function focusedFrameAlive() {
    const frame = BrunOS.focusedFrame;
    if (frame && frame.isConnected && frame.contentWindow) return true;
    BrunOS.focusedFrame = null;
    return false;
}

/// A qué iframe va un evento y con qué argumentos, para que Swift se lo mande.
///
/// Las coordenadas se pasan a las del documento del iframe: se resta dónde
/// empieza su contenido, que es el marco menos el borde y el relleno.
///
/// **Nada viaja por la página.** Antes se reenviaba con `postMessage` y una
/// clave, pero un iframe sin inyector (un `about:blank` que crea la propia
/// página) recibía la clave y la página podía usarla para fabricar clics en
/// otro iframe, como el de un pago. Ahora el camino es Swift, que la página
/// no puede tocar.
function forwardToFrame(frame, x, y, rest) {
    const rect = frame.getBoundingClientRect();
    const style = window.getComputedStyle(frame);
    const left = rect.left + frame.clientLeft + (parseFloat(style.paddingLeft) || 0);
    const top = rect.top + frame.clientTop + (parseFloat(style.paddingTop) || 0);
    return { frame: frameTarget(frame), args: [x - left, y - top].concat(rest) };
}

/// Lo que Swift necesita para encontrar el iframe entre los registrados.
function frameTarget(frame) {
    return { src: frame.src || '', name: frame.name || '' };
}

/// Lo que se puede reenviar a un iframe.
const FRAME_OPS = { click: click, hover: hover, wheel: wheel, key: key, insertText: insertText };

/// Cada iframe se presenta a Swift al cargar, por un canal que sólo existe en
/// el mundo de contenido de BrunOS: la página ni lo ve ni puede escribir en él.
/// Swift se queda con su `WKFrameInfo` para poder hablarle luego.
if (window.top !== window) {
    try {
        window.webkit.messageHandlers.brunosFrame.postMessage(location.href);
    } catch (error) {}
}

// Lo que Swift puede llamar.
window.__brunos = {
    /// La entrada de los eventos que pueden acabar en un iframe: devuelve
    /// `{frame, args}` si hay que reenviarlo.
    op: function (name, args) {
        const operation = FRAME_OPS[name];
        return operation ? operation.apply(null, args) : null;
    },
    click: click,
    hover: hover,
    wheel: wheel,
    describe: describe,
    insertText: insertText,
    key: key,
    fillLogin: fillLogin,
    media: mediaItems,
    reader: readerArticle,
    mediaAt: mediaAt,
    iconURL: iconURL,
};
