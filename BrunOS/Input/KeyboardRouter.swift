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
        Shortcuts.all.map { entry in
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

    private func forward(_ key: UIKey, phase: KeyEvent.Phase) -> Bool {
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
