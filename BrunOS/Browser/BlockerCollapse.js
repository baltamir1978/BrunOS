// Pliega los huecos que deja el bloqueador, como hace uBlock Origin.
//
// POR QUÉ EXISTE ESTO
//
// Cuando WebKit bloquea un anuncio, el elemento que lo iba a enseñar sigue en
// la página: una imagen rota o un iframe vacío, con su tamaño y a menudo con
// fondo gris. uBlock los esconde porque ve qué peticiones ha bloqueado; aquí
// WebKit no lo cuenta, así que:
//
// - Las imágenes (y `embed`/`object`) avisan con `error` al no llegar: se
//   esconden, y si luego cargan (una imagen perezosa que cambia de `src`)
//   vuelven a verse.
// - Los iframes no avisan de nada. Se pregunta a Swift por su dominio
//   (`brunosCollapse`), y si es uno que las listas bloquean entero
//   (`ContentBlocker.isBlockedHost`), se esconde.
//
// Lo que queda —el recuadro gris de alrededor, el «Publicidad»— lo quitan las
// reglas de ocultación de las propias listas (`##.anuncio`), que el conversor
// ya traduce.
//
// Corre en el mundo de BrunOS, en todos los marcos: la página no lo ve.

'use strict';

(function () {
    if (window.__brunosCollapse) return;
    const handlers = window.webkit && window.webkit.messageHandlers;
    const channel = handlers && handlers.brunosCollapse;
    if (!channel) return;

    const collapsed = new WeakSet();
    /// `null` mientras Swift no ha contestado; entonces se guarda lo pendiente.
    let enabled = null;
    const pendingErrors = [];
    /// Dominio → si está bloqueado, ya contestado.
    const answers = new Map();
    /// Dominios preguntados y sin respuesta todavía.
    const asked = new Set();
    /// Dominio → iframes esperando respuesta.
    const waiting = new Map();
    let flushTimer = null;

    function collapse(element) {
        if (collapsed.has(element)) return;
        collapsed.add(element);
        element.style.setProperty('display', 'none', 'important');
    }

    function restore(element) {
        if (!collapsed.has(element)) return;
        collapsed.delete(element);
        element.style.removeProperty('display');
    }

    function hostOf(frame) {
        const source = frame.getAttribute('src');
        if (!source) return null;
        try {
            const url = new URL(source, location.href);
            if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
            return url.hostname === location.hostname ? null : url.hostname;
        } catch (error) {
            return null;
        }
    }

    function considerFrame(frame) {
        if (frame.tagName !== 'IFRAME' && frame.tagName !== 'FRAME') return;
        const host = hostOf(frame);
        if (!host) return;
        if (answers.has(host)) {
            if (answers.get(host) && enabled) collapse(frame);
            return;
        }
        if (!waiting.has(host)) waiting.set(host, []);
        waiting.get(host).push(frame);
        if (!flushTimer) flushTimer = setTimeout(flush, 250);
    }

    function scan(root) {
        if (root.tagName === 'IFRAME' || root.tagName === 'FRAME') {
            considerFrame(root);
        } else if (root.querySelectorAll) {
            for (const frame of root.querySelectorAll('iframe, frame')) considerFrame(frame);
        }
    }

    function flush() {
        flushTimer = null;
        const hosts = [];
        for (const host of waiting.keys()) {
            if (!answers.has(host) && !asked.has(host)) {
                asked.add(host);
                hosts.push(host);
            }
        }
        if (hosts.length) channel.postMessage({ hosts: hosts });
    }

    const COLLAPSIBLE = new Set(['IMG', 'EMBED', 'OBJECT', 'INPUT']);

    document.addEventListener('error', function (event) {
        const target = event.target;
        if (!target || !COLLAPSIBLE.has(target.tagName)) return;
        if (target.tagName === 'INPUT' && target.type !== 'image') return;
        if (enabled === null) {
            pendingErrors.push(target);
        } else if (enabled) {
            collapse(target);
        }
    }, true);

    document.addEventListener('load', function (event) {
        // Sólo imágenes: un iframe bloqueado también puede dar `load`.
        if (event.target && COLLAPSIBLE.has(event.target.tagName)) restore(event.target);
    }, true);

    new MutationObserver(function (records) {
        for (const record of records) {
            if (record.type === 'attributes') {
                considerFrame(record.target);
                continue;
            }
            for (const node of record.addedNodes) {
                if (node.nodeType === 1) scan(node);
            }
        }
    }).observe(document, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['src'],
    });

    document.addEventListener('DOMContentLoaded', function () { scan(document); });

    // Lo que Swift llama con la respuesta, en este mismo marco.
    window.__brunosCollapse = {
        answer: function (reply) {
            enabled = !!reply.enabled;
            const blocked = reply.blocked || {};
            for (const host of Object.keys(blocked)) {
                answers.set(host, !!blocked[host]);
                asked.delete(host);
            }
            for (const [host, frames] of waiting) {
                if (!answers.has(host)) continue;
                if (answers.get(host) && enabled) frames.forEach(collapse);
                waiting.delete(host);
            }
            if (enabled) pendingErrors.forEach(collapse);
            pendingErrors.length = 0;
        },
    };

    // La primera pregunta, aunque no haya iframes: dice si en esta página
    // el bloqueador está encendido.
    channel.postMessage({ hosts: [] });
})();
