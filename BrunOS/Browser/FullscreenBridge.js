// Pantalla completa de la página (YouTube, Plex…), hecha por BrunOS.
//
// POR QUÉ EXISTE ESTO
//
// La pantalla completa de verdad de WebKit no sirve aquí por dos motivos:
//
// 1. Exige un gesto del usuario, y los clics y las teclas de BrunOS son
//    sintéticos (`isTrusted = false`, ver ClickInjector.js): el botón de
//    pantalla completa de YouTube, o su tecla F, se quedaban sin hacer nada.
// 2. En iOS, WebKit la presenta en una ventana suya, y la pantalla externa de
//    BrunOS no es interactiva: no está claro ni en qué pantalla saldría.
//
// Así que se sustituye la API: `requestFullscreen` marca el elemento, lo
// estira a toda la página con CSS y avisa a Swift (`brunosFullscreen`), que
// esconde las barras del navegador y lleva la ventana a todo el monitor. La
// página ve lo mismo que con la de verdad: `document.fullscreenElement`, los
// eventos `fullscreenchange` y `exitFullscreen`.
//
// Dentro de un iframe (un YouTube incrustado), el elemento se estira dentro
// del iframe y se le pide al de fuera que estire el iframe, hasta arriba.
//
// Va en el mundo de la página: tiene que verlo el JavaScript del sitio.

(function () {
    'use strict';
    if (window.__brunosFullscreen) return;

    const isTop = window === window.top;
    const ATTRIBUTE = 'data-brunos-fullscreen';
    const ANCESTOR = 'data-brunos-fullscreen-ancestor';
    let current = null;

    function injectStyle() {
        if (document.getElementById('__brunos_fullscreen_style')) return;
        const style = document.createElement('style');
        style.id = '__brunos_fullscreen_style';
        style.textContent = `
            [${ATTRIBUTE}] {
                position: fixed !important; inset: 0 !important;
                width: 100vw !important; height: 100vh !important;
                max-width: none !important; max-height: none !important;
                min-width: 0 !important; min-height: 0 !important;
                margin: 0 !important; padding: 0 !important; border: 0 !important;
                transform: none !important; z-index: 2147483647 !important;
                background: #000 !important;
            }
            video[${ATTRIBUTE}], [${ATTRIBUTE}] video { object-fit: contain; }
            /* Un antepasado con transform o filter haría que el fixed fuera
               relativo a él, y no a la ventana. */
            [${ANCESTOR}] {
                transform: none !important; filter: none !important; perspective: none !important;
                contain: none !important; will-change: auto !important;
                z-index: 2147483647 !important; overflow: visible !important;
            }
            html.brunos-fullscreen, html.brunos-fullscreen body { overflow: hidden !important; }
        `;
        (document.head || document.documentElement).appendChild(style);
    }

    function notify(on) {
        if (isTop) {
            const handler = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.brunosFullscreen;
            if (handler) handler.postMessage(on);
        } else {
            window.parent.postMessage({ __brunosFullscreen: on }, '*');
        }
    }

    function fire(element) {
        for (const name of ['fullscreenchange', 'webkitfullscreenchange']) {
            const target = element && element.isConnected ? element : document;
            target.dispatchEvent(new Event(name, { bubbles: true }));
        }
    }

    function mark(element, on) {
        if (on) {
            element.setAttribute(ATTRIBUTE, '');
        } else {
            element.removeAttribute(ATTRIBUTE);
        }
        for (let node = element.parentElement; node; node = node.parentElement) {
            if (on) node.setAttribute(ANCESTOR, ''); else node.removeAttribute(ANCESTOR);
        }
        document.documentElement.classList.toggle('brunos-fullscreen', on);
    }

    function enter(element) {
        if (!(element instanceof Element)) return Promise.reject(new TypeError('No es un elemento'));
        if (current === element) return Promise.resolve();
        injectStyle();
        if (current) mark(current, false);
        current = element;
        mark(element, true);
        notify(true);
        fire(element);
        return Promise.resolve();
    }

    /// `fromParent`: lo pide el marco de fuera, que ya ha salido.
    function exit(fromParent) {
        if (!current) return Promise.resolve();
        const element = current;
        current = null;
        mark(element, false);
        // Si lo que estaba a pantalla completa era un iframe, que salga él
        // también.
        if (element.tagName === 'IFRAME' && element.contentWindow) {
            element.contentWindow.postMessage({ __brunosFullscreenExit: true }, '*');
        }
        if (!fromParent) notify(false);
        fire(element);
        return Promise.resolve();
    }

    function define(target, name, descriptor) {
        try {
            Object.defineProperty(target, name, Object.assign({ configurable: true }, descriptor));
        } catch (error) {}
    }

    const getCurrent = { get: function () { return current; } };
    const isOn = { get: function () { return current !== null; } };
    const enabled = { get: function () { return true; } };

    define(Document.prototype, 'fullscreenElement', getCurrent);
    define(Document.prototype, 'webkitFullscreenElement', getCurrent);
    define(Document.prototype, 'webkitCurrentFullScreenElement', getCurrent);
    define(Document.prototype, 'fullscreen', isOn);
    define(Document.prototype, 'webkitIsFullScreen', isOn);
    define(Document.prototype, 'fullscreenEnabled', enabled);
    define(Document.prototype, 'webkitFullscreenEnabled', enabled);

    define(Element.prototype, 'requestFullscreen', { value: function () { return enter(this); }, writable: true });
    define(Element.prototype, 'webkitRequestFullscreen', { value: function () { enter(this); }, writable: true });
    define(Element.prototype, 'webkitRequestFullScreen', { value: function () { enter(this); }, writable: true });
    define(Document.prototype, 'exitFullscreen', { value: function () { return exit(false); }, writable: true });
    define(Document.prototype, 'webkitExitFullscreen', { value: function () { exit(false); }, writable: true });
    define(Document.prototype, 'webkitCancelFullScreen', { value: function () { exit(false); }, writable: true });

    // La pantalla completa sólo de vídeo de Safari en iOS.
    define(HTMLVideoElement.prototype, 'webkitEnterFullscreen', { value: function () { enter(this); }, writable: true });
    define(HTMLVideoElement.prototype, 'webkitEnterFullScreen', { value: function () { enter(this); }, writable: true });
    define(HTMLVideoElement.prototype, 'webkitExitFullscreen', { value: function () { exit(false); }, writable: true });
    define(HTMLVideoElement.prototype, 'webkitSupportsFullscreen', enabled);
    define(HTMLVideoElement.prototype, 'webkitDisplayingFullscreen', {
        get: function () { return current === this; },
    });

    // Los iframes de dentro piden estirarse, o el de fuera les dice que salgan.
    window.addEventListener('message', function (event) {
        const data = event.data;
        if (!data || typeof data !== 'object') return;
        if (data.__brunosFullscreenExit === true && event.source === window.parent) {
            exit(true);
            return;
        }
        if (typeof data.__brunosFullscreen !== 'boolean') return;
        const frame = Array.from(document.querySelectorAll('iframe'))
            .find(function (candidate) { return candidate.contentWindow === event.source; });
        if (!frame) return;
        if (data.__brunosFullscreen) {
            enter(frame);
        } else if (current === frame) {
            exit(false);
        }
    });

    // Lo que Swift llama: Esc, o cuando la ventana deja la pantalla completa.
    window.__brunosFullscreen = { exit: function () { exit(false); } };
})();
