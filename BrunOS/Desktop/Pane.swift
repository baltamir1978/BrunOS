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

    /// Si en ese punto se puede agarrar el panel para arrastrarlo: la parte
    /// vacía de su barra, como la barra de título de una ventana de macOS.
    /// Nunca un botón, una pestaña o la barra de direcciones.
    func isDragArea(_ point: CGPoint) -> Bool
}

extension Pane {
    func insertText(_ text: String) {}
    func isDragArea(_ point: CGPoint) -> Bool { false }
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

    /// Lo que la tecla escribe, si escribe algo.
    ///
    /// **No vale `key.characters` a pelo** en un campo propio: las flechas, las
    /// teclas de función e Inicio traen caracteres del área privada de Unicode
    /// (`U+F700` y siguientes), y Tab o Intro, caracteres de control. Metidos
    /// en un buscador, lo dejaban sin resultados con basura invisible.
    @MainActor var typedText: String? {
        let characters = key.characters
        guard !characters.isEmpty,
              !key.modifierFlags.contains(.command),
              !key.modifierFlags.contains(.control)
        else { return nil }
        let printable = characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0xF700...0xF8FF).contains(scalar.value)
        }
        return printable ? characters : nil
    }
}
