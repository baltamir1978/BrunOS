import UIKit

/// Claro u oscuro en la pantalla externa.
///
/// Al principio el escritorio iba **siempre oscuro**. Era una decisión de
/// estética que no aguantó el uso: con el iPhone en modo claro, el monitor
/// seguía en negro, y todo lo que no era el terminal se veía apagado. Ahora
/// sigue al iPhone por defecto, y se puede fijar a mano en Ajustes.
///
/// El terminal tiene su propio ajuste (`TerminalTheme`), que por defecto sigue
/// a éste.
enum DesktopAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: "como el iPhone"
        case .light: "claro"
        case .dark: "oscuro"
        }
    }
}

/// El modo resuelto que usa el escritorio en cada momento.
///
/// Es global y no una propiedad del escritorio porque lo necesita
/// `UIColor.desktopCGColor`, que se llama desde cualquier vista de la pantalla
/// externa, incluidas las que todavía no cuelgan de ningún sitio.
@MainActor
enum DesktopTheme {

    static let didChangeNotification = Notification.Name("BrunOSDesktopThemeDidChange")

    private static let key = "desktop.appearance"

    /// Lo elegido en Ajustes.
    static var appearance: DesktopAppearance {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(DesktopAppearance.init(rawValue:)) ?? .system
        }
        set {
            let before = style
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            if style != before { notify() }
        }
    }

    /// El modo del iPhone. Lo mantiene al día `PhoneRootViewController`, que es
    /// el único sitio donde se sabe: la escena externa no hereda el del teléfono
    /// de forma fiable, y un monitor no tiene modo propio.
    static var phoneStyle: UIUserInterfaceStyle = .light {
        didSet {
            guard phoneStyle != oldValue, appearance == .system else { return }
            notify()
        }
    }

    /// Claro u oscuro, ya resuelto: nunca `.unspecified`.
    static var style: UIUserInterfaceStyle {
        switch appearance {
        case .light: .light
        case .dark: .dark
        case .system: phoneStyle == .dark ? .dark : .light
        }
    }

    private static func notify() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
