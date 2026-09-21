import UIKit

/// Teclado en pantalla del iPhone, escribiendo hacia el panel con foco.
///
/// Es un campo de texto invisible que se hace first responder: iOS levanta el
/// teclado y cada carácter se reenvía al escritorio. No se enseña nada de lo
/// escrito aquí, porque lo escrito sale en el monitor.
///
/// **Mientras está activo, el teclado físico deja de encaminarse** por el
/// `KeyboardRouter`, ya que el first responder pasa a ser este campo. Es lo
/// razonable: son dos formas de escribir y sólo una puede mandar a la vez.
@MainActor
final class OnScreenKeyboardField: UITextField, UITextFieldDelegate {

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        isHidden = false
        // Invisible, pero no `isHidden`: una vista oculta no puede ser first
        // responder y el teclado no llegaría a salir.
        alpha = 0.01
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        // Un terminal necesita comillas rectas y guiones sin "mejorar".
        keyboardType = .asciiCapable
        returnKeyType = .default
        accessibilityLabel = "Escribir en el panel con foco"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        if string.isEmpty {
            // Retroceso: se manda como carácter de borrado, que es lo que
            // entiende un terminal.
            AppServices.shared.desktopViewController?.insertText("\u{7F}")
        } else {
            AppServices.shared.desktopViewController?.insertText(string)
        }
        // Nunca se acumula texto aquí: este campo no guarda nada.
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        AppServices.shared.desktopViewController?.insertText("\n")
        return false
    }
}
