import UIKit

/// Lo que el gestor de ventanas necesita saber de un panel, sea terminal,
/// navegador o gestor de ficheros.
///
/// La pantalla externa no es interactiva, así que **ningún panel recibe eventos
/// del sistema**: el puntero y el teclado llegan desde la escena del iPhone y se
/// entregan por estos métodos.
@MainActor
protocol Pane: AnyObject {

    /// Lo que se rotula en la barra superior cuando este panel tiene el foco.
    var title: String { get }

    /// La vista que el mosaico coloca. Se maqueta en puntos lógicos.
    var view: UIView { get }

    /// El mosaico avisa al cambiar el foco para que el panel pinte su estado.
    func setFocused(_ focused: Bool)

    /// Evento de puntero ya traducido a coordenadas del propio panel.
    func handlePointer(_ event: PointerEvent)

    /// Tecla recibida por la escena del iPhone y encaminada a este panel.
    func handleKey(_ event: KeyEvent)

    /// Texto que llega de una vez, sin pasar por el teclado: del dictado o de
    /// pegar. Los paneles que no acepten texto pueden ignorarlo.
    func insertText(_ text: String)
}

extension Pane {
    func insertText(_ text: String) {}
}

/// Evento de puntero en coordenadas locales del panel.
struct PointerEvent {
    enum Kind {
        case moved
        case down(button: Button)
        case up(button: Button)
        case scroll(delta: CGVector)
    }

    enum Button {
        case left, right, middle
    }

    var kind: Kind
    var location: CGPoint
    var modifiers: UIKeyModifierFlags
}

/// Tecla encaminada desde el `KeyboardRouter` de la escena del iPhone.
struct KeyEvent {
    enum Phase {
        case down, up
    }

    var phase: Phase
    var key: UIKey
}
