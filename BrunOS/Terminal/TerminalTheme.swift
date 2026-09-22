import SwiftTerm
import UIKit

/// Claro u oscuro en el terminal, por separado del escritorio.
///
/// Por defecto sigue al escritorio, como hace Terminal en macOS. Pero hay
/// quien quiere la consola oscura aunque todo lo demás vaya en claro, y por eso
/// se puede fijar en Ajustes del terminal.
@MainActor
enum TerminalTheme {

    static let didChangeNotification = Notification.Name("BrunOSTerminalThemeDidChange")

    private static let key = "terminal.appearance"

    static var appearance: DesktopAppearance {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(DesktopAppearance.init(rawValue:)) ?? .system
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// Cuerpo de letra por defecto. Cmd + y Cmd − lo cambian sólo en la sesión
    /// abierta; Cmd 0 vuelve a éste.
    static var fontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: "terminal.fontSize")
            return stored > 0 ? CGFloat(stored) : 13
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: "terminal.fontSize")
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// En el terminal, `.system` quiere decir «como el escritorio».
    static var style: UIUserInterfaceStyle {
        switch appearance {
        case .light: .light
        case .dark: .dark
        case .system: DesktopTheme.style
        }
    }

    static func label(for appearance: DesktopAppearance) -> String {
        appearance == .system ? "como el escritorio" : appearance.label
    }

    static func background(for style: UIUserInterfaceStyle) -> UIColor {
        style == .dark ? UIColor(hex: 0x0F1114) : UIColor(hex: 0xFBFAF7)
    }

    static func foreground(for style: UIUserInterfaceStyle) -> UIColor {
        style == .dark ? UIColor(hex: 0xE6E3DC) : UIColor(hex: 0x1B1E22)
    }

    /// Los 16 colores ANSI.
    ///
    /// **La paleta clara no es la de serie.** La de xterm está pensada para
    /// fondo negro: sobre blanco, el amarillo y el blanco de `ls --color` o de
    /// la barra de tmux no se leen. Aquí se oscurecen los claros y el «blanco»
    /// pasa a ser gris, como hacen las paletas claras de cualquier terminal.
    static func palette(for style: UIUserInterfaceStyle) -> [SwiftTerm.Color] {
        let hex: [UInt32] = style == .dark
            ? [
                0x1D2127, 0xE05C4B, 0x7FB86A, 0xE8A33D, 0x5C9FE0, 0xB07FD8, 0x4FB3A3, 0xC9C6BF,
                0x5C636D, 0xFF7A68, 0x9DD68A, 0xF4C069, 0x82B9F0, 0xCB9FEB, 0x74D0C1, 0xF4F2EC,
            ]
            : [
                0x1B1E22, 0xC0392B, 0x3D7A2A, 0x9A6300, 0x2462B0, 0x7F3FA8, 0x1F7A6C, 0x9AA0A8,
                0x5C636D, 0xD9483A, 0x4E9435, 0xB47A06, 0x3478CC, 0x9552C2, 0x2A9483, 0x6E757F,
            ]
        return hex.map { value in
            SwiftTerm.Color(
                red8: UInt16((value >> 16) & 0xFF),
                green8: UInt16((value >> 8) & 0xFF),
                blue8: UInt16(value & 0xFF)
            )
        }
    }
}
