import UIKit

/// Baja el brillo de la pantalla del iPhone y lo devuelve como estaba.
///
/// El brillo es un ajuste **del sistema**, no de la app: lo que se toque aquí
/// sigue así al salir. Por eso se guarda el de antes y se restaura siempre,
/// también si BrunOS pasa a segundo plano con la pantalla atenuada.
@MainActor
enum ScreenDimmer {

    private static var saved: CGFloat?

    /// La pantalla del propio iPhone, no la del monitor.
    private static var phoneScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }?
            .screen
    }

    static func dim() {
        guard let screen = phoneScreen, saved == nil else { return }
        saved = screen.brightness
        screen.brightness = 0
    }

    static func restore() {
        guard let screen = phoneScreen, let saved else { return }
        screen.brightness = saved
        self.saved = nil
    }
}
