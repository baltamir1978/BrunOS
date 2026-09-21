import SwiftUI
import UIKit

/// Tokens de diseño de BrunOS. Única fuente de verdad para colores, tipografías
/// y espaciados: nada de literales de color repartidos por las vistas.
///
/// En el iPhone la interfaz es SwiftUI y adopta Liquid Glass, pero teñido con
/// estos colores. En la pantalla externa el estilo es propio y plano.
enum Tokens {

    // MARK: - Colores

    /// Los colores del iPhone **siguen el modo del sistema**; los de la pantalla
    /// externa, no: el escritorio va siempre oscuro, porque es una estación de
    /// trabajo delante de la que uno se sienta a mirar texto, no una app que
    /// convenga en blanco a mediodía. `DesktopViewController` fuerza `.dark`.
    ///
    /// La paleta clara no es la oscura invertida. Dos ajustes que importan:
    /// el ámbar y el turquesa se **oscurecen** sobre fondo claro, porque los de
    /// la paleta oscura no llegan al contraste mínimo legible; y el fondo del
    /// terminal se queda oscuro en los dos modos, que es lo que espera
    /// cualquiera que use una consola.
    enum Color {
        static let background = dynamic(dark: 0x0B0D10, light: 0xF6F4F0)
        static let panel = dynamic(dark: 0x15181D, light: 0xFFFFFF)
        /// Panel elevado: menús, lanzador, diálogos.
        static let panelElevated = dynamic(dark: 0x1D2127, light: 0xEDEAE4)
        static let border = dynamic(dark: 0x262B33, light: 0xD7D2C8)
        static let text = dynamic(dark: 0xE6E3DC, light: 0x16191D)
        static let textSecondary = dynamic(dark: 0x9AA1AB, light: 0x5C636D)
        /// Ámbar de marca: foco, selección y espacio de trabajo activo.
        static let accent = dynamic(dark: 0xE8A33D, light: 0xA96B06)
        /// Turquesa: estados correctos, bloqueador activo, barra de tmux.
        static let accentAlt = dynamic(dark: 0x4FB3A3, light: 0x2A7A6C)
        /// Una consola es oscura en cualquier modo.
        static let terminalBackground = UIColor(hex: 0x0F1114)

        private static func dynamic(dark: UInt32, light: UInt32) -> UIColor {
            UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(hex: dark)
                    : UIColor(hex: light)
            }
        }
    }

    // MARK: - Tipografía

    /// Los nombres PostScript de IBM Plex Sans están abreviados dentro del TTF
    /// (`IBMPlexSans-Medm`, `IBMPlexSans-SmBld`, y el Regular es `IBMPlexSans`
    /// a secas). Usar "IBMPlexSans-Medium" devuelve nil y UIKit cae en
    /// San Francisco sin avisar. Estos son los nombres reales.
    enum FontName {
        static let mono = "JetBrainsMono-Regular"
        static let monoBold = "JetBrainsMono-Bold"
        static let monoItalic = "JetBrainsMono-Italic"
        static let monoBoldItalic = "JetBrainsMono-BoldItalic"
        static let sans = "IBMPlexSans"
        static let sansMedium = "IBMPlexSans-Medm"
        static let sansSemiBold = "IBMPlexSans-SmBld"
    }

    /// JetBrains Mono: marca, terminal, rutas y URLs.
    static func mono(_ size: CGFloat, bold: Bool = false) -> UIFont {
        UIFont(name: bold ? FontName.monoBold : FontName.mono, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// IBM Plex Sans: el resto de la interfaz.
    static func sans(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let name = switch weight {
        case .semibold, .bold, .heavy, .black: FontName.sansSemiBold
        case .medium: FontName.sansMedium
        default: FontName.sans
        }
        return UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    // MARK: - Métricas

    enum Metric {
        /// Alto de la barra superior del escritorio, en puntos lógicos.
        static let topBarHeight: CGFloat = 34
        /// Separación entre paneles del mosaico.
        static let tileGap: CGFloat = 8
        /// Grosor del borde del panel con foco.
        static let focusBorderWidth: CGFloat = 1.5
        static let paneCornerRadius: CGFloat = 10
        static let controlCornerRadius: CGFloat = 7
        /// Mínimo táctil en el iPhone.
        static let touchTarget: CGFloat = 44
    }
}

// MARK: - Puentes

extension UIColor {
    /// Inicializa desde un literal 0xRRGGBB. Los tokens se escriben así para
    /// que se lean igual que en la tabla de diseño.
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension SwiftUI.Color {
    static let brunosBackground = SwiftUI.Color(Tokens.Color.background)
    static let brunosPanel = SwiftUI.Color(Tokens.Color.panel)
    static let brunosPanelElevated = SwiftUI.Color(Tokens.Color.panelElevated)
    static let brunosBorder = SwiftUI.Color(Tokens.Color.border)
    static let brunosText = SwiftUI.Color(Tokens.Color.text)
    static let brunosTextSecondary = SwiftUI.Color(Tokens.Color.textSecondary)
    static let brunosAccent = SwiftUI.Color(Tokens.Color.accent)
    static let brunosAccentAlt = SwiftUI.Color(Tokens.Color.accentAlt)
}

extension SwiftUI.Font {
    static func brunosMono(_ size: CGFloat, bold: Bool = false) -> SwiftUI.Font {
        .custom(bold ? Tokens.FontName.monoBold : Tokens.FontName.mono, size: size)
    }

    static func brunosSans(_ size: CGFloat, weight: UIFont.Weight = .regular) -> SwiftUI.Font {
        let name = switch weight {
        case .semibold, .bold, .heavy, .black: Tokens.FontName.sansSemiBold
        case .medium: Tokens.FontName.sansMedium
        default: Tokens.FontName.sans
        }
        return .custom(name, size: size)
    }
}
