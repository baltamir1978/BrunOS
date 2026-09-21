import SwiftUI
import UIKit

/// Tokens de diseño de BrunOS. Única fuente de verdad para colores, tipografías
/// y espaciados: nada de literales de color repartidos por las vistas.
///
/// En el iPhone la interfaz es SwiftUI y adopta Liquid Glass, pero teñido con
/// estos colores. En la pantalla externa el estilo es propio y plano.
enum Tokens {

    // MARK: - Colores

    enum Color {
        /// Fondo general del escritorio.
        static let background = UIColor(hex: 0x0B0D10)
        /// Fondo de un panel.
        static let panel = UIColor(hex: 0x15181D)
        /// Panel elevado: menús, lanzador, diálogos.
        static let panelElevated = UIColor(hex: 0x1D2127)
        /// Bordes y divisores del mosaico.
        static let border = UIColor(hex: 0x262B33)
        static let text = UIColor(hex: 0xE6E3DC)
        static let textSecondary = UIColor(hex: 0x9AA1AB)
        /// Ámbar de marca: foco, selección y espacio de trabajo activo.
        static let accent = UIColor(hex: 0xE8A33D)
        /// Turquesa: estados correctos, bloqueador activo, barra de tmux.
        static let accentAlt = UIColor(hex: 0x4FB3A3)
        /// Fondo del terminal, algo más oscuro que el de un panel normal.
        static let terminalBackground = UIColor(hex: 0x0F1114)
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
