import GameController
import UIKit

@MainActor
protocol KeyboardRouterDelegate: AnyObject {
    /// Un atajo del gestor de ventanas. Devolver `true` si se consumió.
    func keyboardRouter(_ router: KeyboardRouter, didReceive command: DesktopCommand) -> Bool
    /// Una tecla normal, que va al panel con foco.
    func keyboardRouter(_ router: KeyboardRouter, didReceiveKey event: KeyEvent)
}

/// Lleva el teclado físico desde la escena del iPhone hasta el panel con foco
/// de la pantalla externa.
///
/// Existe por una razón de fondo: **la escena externa no es interactiva**, así
/// que jamás recibe un evento de teclado. Todo entra por el first responder de
/// la ventana del iPhone y hay que reenviarlo a mano.
///
/// El reparto es: lo que lleve Cmd se mira en la tabla de atajos; **todo lo
/// demás, incluido cualquier cosa con Ctrl u Option, va derecho al panel**, que
/// es lo que hace que el terminal siga siendo un terminal.
final class KeyboardRouter: UIResponder {

    weak var delegate: (any KeyboardRouterDelegate)?

    /// A quién le toca después. Lo rellena `PhoneRootViewController` al
    /// insertarse en la cadena, para que lo que aquí no se consuma siga su
    /// camino normal hacia la ventana y la aplicación.
    weak var nextInChain: UIResponder?

    override var next: UIResponder? { nextInChain }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - Atajos

    /// Los `UIKeyCommand` los reparte el sistema y ganan al `pressesBegan`.
    /// Se registran sólo los del escritorio; el resto de teclas no se declara
    /// aquí a propósito, para que lleguen crudas al panel.
    override var keyCommands: [UIKeyCommand]? {
        // Con un campo de texto activo en el iPhone tampoco se registran los
        // atajos: Cmd+C tiene que copiar del campo, no del terminal.
        guard !isEditingOnPhone else { return nil }

        return Shortcuts.all.map { entry in
            let command = UIKeyCommand(
                title: entry.title,
                action: #selector(handleKeyCommand(_:)),
                input: entry.input,
                modifierFlags: entry.modifiers
            )
            // Sin esto, iOS rotula el atajo encima del contenido cada vez que
            // se mantiene Cmd pulsado, y en el escritorio estorba.
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func handleKeyCommand(_ sender: UIKeyCommand) {
        guard let input = sender.input,
              let command = Shortcuts.command(input: input, modifiers: sender.modifierFlags)
        else { return }
        _ = delegate?.keyboardRouter(self, didReceive: command)
    }

    // MARK: - Teclas normales

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            if forward(key, phase: .down) { handled = true }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            _ = forward(key, phase: .up)
        }
        super.pressesEnded(presses, with: event)
    }

    /// Si hay un campo de texto con el foco en la interfaz del iPhone.
    ///
    /// **Mientras lo haya, el router no toca nada.** Si no, al abrir los
    /// ajustes o el editor de máquinas las teclas se iban al monitor y era
    /// imposible escribir en el teléfono: el router se las quedaba todas.
    private var isEditingOnPhone: Bool {
        UIResponder.brunosCurrentFirstResponder is any UITextInput
    }

    // MARK: - Modificadores pulsados

    /// Los modificadores que se tienen pulsados ahora mismo, para el ratón.
    ///
    /// **El puntero no trae modificadores**: con AssistiveTouch, un clic es un
    /// toque en el iPhone, y el toque no sabe nada del teclado. Todos los
    /// clics llegaban con `[]`, así que Cmd+clic y Mayús+clic no hacían nada.
    /// Se leen del teclado con `GCKeyboard`, que da el estado de cada tecla al
    /// momento; si no hay, de lo que se ha visto pasar por aquí.
    static var heldModifiers: UIKeyModifierFlags {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return trackedModifiers }
        func pressed(_ codes: GCKeyCode...) -> Bool {
            codes.contains { input.button(forKeyCode: $0)?.isPressed == true }
        }
        var flags: UIKeyModifierFlags = []
        if pressed(.leftGUI, .rightGUI) { flags.insert(.command) }
        if pressed(.leftShift, .rightShift) { flags.insert(.shift) }
        if pressed(.leftAlt, .rightAlt) { flags.insert(.alternate) }
        if pressed(.leftControl, .rightControl) { flags.insert(.control) }
        return flags
    }

    private static var trackedModifiers: UIKeyModifierFlags = []

    private static func track(_ key: UIKey, phase: KeyEvent.Phase) {
        let flag: UIKeyModifierFlags? = switch key.keyCode {
        case .keyboardLeftGUI, .keyboardRightGUI: .command
        case .keyboardLeftShift, .keyboardRightShift: .shift
        case .keyboardLeftAlt, .keyboardRightAlt: .alternate
        case .keyboardLeftControl, .keyboardRightControl: .control
        default: nil
        }
        if let flag {
            if phase == .down { trackedModifiers.insert(flag) } else { trackedModifiers.remove(flag) }
        } else {
            // Una tecla normal trae los modificadores de verdad: si se perdió
            // el soltar de alguno, aquí se corrige.
            trackedModifiers = key.modifierFlags.intersection([.command, .shift, .alternate, .control])
        }
    }

    private func forward(_ key: UIKey, phase: KeyEvent.Phase) -> Bool {
        guard !isEditingOnPhone else { return false }
        Self.track(key, phase: phase)

        // Cmd+º, el conmutador de ventanas. Va por el código de la tecla, no
        // por la tabla: lo que escribe cambia con la distribución del teclado.
        if key.modifierFlags.contains(.command), Shortcuts.windowSwitchKeys.contains(key.keyCode) {
            if phase == .down {
                let backwards = key.modifierFlags.contains(.shift)
                _ = delegate?.keyboardRouter(self, didReceive: .switchWindow(backwards: backwards))
            }
            return true
        }
        // Al soltar Cmd, el conmutador va a la ventana elegida. La tecla sigue
        // su camino al panel, como antes.
        if phase == .up, key.keyCode == .keyboardLeftGUI || key.keyCode == .keyboardRightGUI {
            _ = delegate?.keyboardRouter(self, didReceive: .endWindowSwitch)
        }

        // Con Cmd pulsado manda la tabla de atajos. Si la combinación no está
        // en ella, se deja pasar: puede ser Cmd+C o Cmd+V, que son del panel.
        if key.modifierFlags.contains(.command),
           let command = Shortcuts.command(
               input: key.charactersIgnoringModifiers,
               modifiers: key.modifierFlags
           ) {
            guard phase == .down else { return true }
            return delegate?.keyboardRouter(self, didReceive: command) ?? false
        }

        delegate?.keyboardRouter(self, didReceiveKey: KeyEvent(phase: phase, key: key))
        return true
    }
}


// MARK: - Quién tiene el foco

extension UIResponder {

    private static weak var brunosFound: UIResponder?

    /// El first responder actual.
    ///
    /// UIKit no lo expone. El truco conocido es mandar una acción a `nil`, que
    /// UIKit entrega precisamente al first responder, y que éste se apunte.
    static var brunosCurrentFirstResponder: UIResponder? {
        brunosFound = nil
        UIApplication.shared.sendAction(
            #selector(brunosCaptureFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        return brunosFound
    }

    @objc private func brunosCaptureFirstResponder() {
        UIResponder.brunosFound = self
    }
}
