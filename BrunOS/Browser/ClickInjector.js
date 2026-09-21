// Inyección de ratón en la página.
//
// POR QUÉ EXISTE ESTO
//
// El ratón de BrunOS no llega de forma nativa al WKWebView: la pantalla externa
// no es interactiva y el cursor lo dibuja la app. Así que los clics, el hover y
// la rueda se sintetizan aquí, a partir de coordenadas que manda Swift.
//
// LÍMITE CONOCIDO, Y NO TIENE ARREGLO
//
// Los eventos sintéticos NO entran en iframes de otro dominio: la política del
// mismo origen impide alcanzar su DOM. Eso deja fuera los avisos de cookies,
// las pasarelas de pago y los inicios de sesión de terceros. No se intenta
// rodear. Para esos casos está "Traer ventana", que enseña la misma página en
// el iPhone para tocarla con el dedo.

'use strict';

const BrunOS = {
    lastHovered: null,
    lastDownTarget: null,
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
    while (element.shadowRoot && guard++ < 20) {
        const inner = element.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === element) break;
        element = inner;
    }
    return element;
}

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

    if (BrunOS.lastHovered !== target) {
        if (BrunOS.lastHovered) {
            BrunOS.lastHovered.dispatchEvent(new MouseEvent('mouseout', base));
            BrunOS.lastHovered.dispatchEvent(new MouseEvent('mouseleave', base));
        }
        target.dispatchEvent(new MouseEvent('mouseover', base));
        target.dispatchEvent(new MouseEvent('mouseenter', base));
        BrunOS.lastHovered = target;
    }

    target.dispatchEvent(new PointerEvent('pointermove', makePointerInit(base)));
    target.dispatchEvent(new MouseEvent('mousemove', base));
    return true;
}

/// Rueda del ratón.
///
/// Se busca el ancestro que de verdad pueda desplazarse y se le mueve a él. Ir
/// directo a `window.scrollBy` fallaría en cualquier página con paneles
/// internos, que son casi todas las modernas.
function wheel(x, y, deltaX, deltaY) {
    const target = deepElementFromPoint(x, y) || document.body;
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

    return {
        tag: tag,
        link: link,
        image: tag === 'img' ? target.src : null,
        editable: editable,
        // Para que la app pueda cambiar la forma del cursor, como un navegador.
        cursor: window.getComputedStyle(target).cursor,
    };
}

/// Escribe texto en el elemento con foco.
///
/// Se dispara `input` a mano porque asignar `.value` no lo genera solo, y sin
/// ese evento React y compañía no se enteran de nada.
function insertText(text) {
    const active = document.activeElement;
    if (!active) return false;

    if (active.isContentEditable) {
        document.execCommand('insertText', false, text);
        return true;
    }

    const tag = active.tagName ? active.tagName.toLowerCase() : '';
    if (tag === 'input' || tag === 'textarea') {
        const start = active.selectionStart ?? active.value.length;
        const end = active.selectionEnd ?? active.value.length;
        active.value = active.value.slice(0, start) + text + active.value.slice(end);
        const caret = start + text.length;
        active.setSelectionRange(caret, caret);
        active.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
        return true;
    }
    return false;
}

// Lo que Swift puede llamar.
window.__brunos = {
    click: click,
    hover: hover,
    wheel: wheel,
    describe: describe,
    insertText: insertText,
};
