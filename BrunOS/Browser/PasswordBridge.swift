import Observation
import UIKit

/// Trae una contraseña del llavero de iOS a una página del navegador.
///
/// **Por qué hace falta un puente.** El autorrelleno de iOS —el de Safari, con
/// Face ID— sólo se ofrece en el teclado del sistema, sobre un campo de texto
/// nativo y con el dedo. En el monitor no hay ni lo uno ni lo otro: la página
/// es un `WKWebView` al que se le escribe a mano. Así que, al pinchar un campo
/// de inicio de sesión, se abre en el iPhone una hoja con dos campos nativos
/// (`PasswordAutoFillView`); iOS ofrece allí las contraseñas guardadas, y lo
/// que se elige se pasa a la página.
///
/// **Nada se guarda.** Usuario y contraseña van de iOS a la página y se
/// olvidan; BrunOS no tiene gestor de contraseñas propio.
@MainActor
@Observable
final class PasswordBridge {

    struct Request: Identifiable {
        let id = UUID()
        /// La web que la pide, para rotularlo en el iPhone.
        let host: String
    }

    /// Lo que está pidiendo una contraseña ahora mismo. La interfaz del iPhone
    /// abre la hoja cuando no es `nil`.
    private(set) var request: Request?

    private var completion: ((String, String) -> Void)?
    private var onCancel: (() -> Void)?

    /// Una web, para que no se vuelva a pedir en el mismo campo después de
    /// cancelar: si se ha dicho que no, se quiere escribir a mano.
    private var declinedHosts: Set<String> = []

    func ask(host: String, completion: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        guard request == nil, !declinedHosts.contains(host) else { return }
        self.completion = completion
        self.onCancel = onCancel
        request = Request(host: host)
    }

    func complete(username: String, password: String) {
        let completion = self.completion
        clear()
        completion?(username, password)
    }

    /// Desde el iPhone o con Esc en el monitor. En esa web no se vuelve a
    /// ofrecer hasta que se cargue otra.
    func cancel() {
        if let host = request?.host { declinedHosts.insert(host) }
        let onCancel = self.onCancel
        clear()
        onCancel?()
    }

    /// Una página nueva vuelve a poder pedirlo.
    func reset(for host: String) {
        declinedHosts.remove(host)
    }

    var isAsking: Bool { request != nil }

    private func clear() {
        request = nil
        completion = nil
        onCancel = nil
        // El teclado físico vuelve a su sitio: mientras la hoja estaba
        // abierta, el primer respondedor era su campo.
        NotificationCenter.default.post(name: .brunosRestoreKeyboard, object: nil)
    }
}

extension Notification.Name {
    /// Devolver el teclado físico al controlador raíz del iPhone.
    static let brunosRestoreKeyboard = Notification.Name("BrunOSRestoreKeyboard")
}
