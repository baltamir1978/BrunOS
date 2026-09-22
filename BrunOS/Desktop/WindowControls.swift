import UIKit

/// Los tres botones de ventana de macOS, en la barra de cada panel.
///
/// Lo que hace cada uno lo decidió Bruno, pensando ya en las ventanas
/// flotantes, y es lo mismo que en macOS:
///
/// - **Rojo**: cierra el panel (y las sesiones o pestañas que tenga dentro).
/// - **Amarillo**: lo manda al dock. Sale del mosaico, pero sigue vivo —la
///   sesión SSH no se corta, la página no se recarga— y vuelve a su sitio al
///   pulsar su icono.
/// - **Verde**: maximizar a pantalla completa, sin dock ni barra superior
///   (Ctrl+Cmd+F). Cmd+Intro sigue maximizando dentro del mosaico.
///
/// Como en macOS, los símbolos sólo salen al pasar el cursor por encima del
/// grupo: en reposo son tres bolitas de color.
@MainActor
enum WindowControls {

    enum Button: CaseIterable {
        case close
        case minimize
        case fullScreen
    }

    static let diameter: CGFloat = 12
    static let spacing: CGFloat = 8
    static var width: CGFloat { diameter * 3 + spacing * 2 }

    /// Las tres bolitas a partir de un origen, centradas en `midY`.
    static func frames(x: CGFloat, midY: CGFloat) -> [(Button, CGRect)] {
        Button.allCases.enumerated().map { index, button in
            (button, CGRect(
                x: x + CGFloat(index) * (diameter + spacing),
                y: midY - diameter / 2,
                width: diameter,
                height: diameter
            ))
        }
    }

    /// Qué botón hay en un punto. Se perdona un poco de puntería: son blancos
    /// de 12 puntos manejados con un cursor.
    static func button(at point: CGPoint, x: CGFloat, midY: CGFloat) -> Button? {
        frames(x: x, midY: midY).first { $0.1.insetBy(dx: -3, dy: -4).contains(point) }?.0
    }

    /// Si el cursor está sobre el grupo, que es cuando salen los símbolos.
    static func groupContains(_ point: CGPoint, x: CGFloat, midY: CGFloat) -> Bool {
        CGRect(x: x - 4, y: midY - diameter / 2 - 5, width: width + 8, height: diameter + 10).contains(point)
    }

    static func draw(in context: CGContext, x: CGFloat, midY: CGFloat, hovering: Bool, scale: CGFloat) {
        let isFullScreen = AppServices.shared.desktop.isFullScreen
        for (button, frame) in frames(x: x, midY: midY) {
            let (fill, symbol): (UInt32, String) = switch button {
            case .close: (0xFF5F57, "xmark")
            case .minimize: (0xFEBC2E, "minus")
            case .fullScreen: (0x28C840, isFullScreen
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
            }
            context.setFillColor(UIColor(hex: fill).cgColor)
            context.fillEllipse(in: frame)
            // El filete oscuro de macOS: separa la bolita de un fondo del mismo
            // tono, que en modo claro con un fondo cálido pasa.
            context.setStrokeColor(UIColor.black.withAlphaComponent(0.14).cgColor)
            context.setLineWidth(0.8)
            context.strokeEllipse(in: frame.insetBy(dx: 0.4, dy: 0.4))

            guard hovering else { continue }
            let configuration = UIImage.SymbolConfiguration(pointSize: 6.5, weight: .black)
            guard let image = UIImage.crispSymbol(symbol, configuration: configuration, scale: scale)?
                .withTintColor(UIColor.black.withAlphaComponent(0.55), renderingMode: .alwaysOriginal)
            else { continue }
            image.draw(at: CGPoint(
                x: frame.midX - image.size.width / 2,
                y: frame.midY - image.size.height / 2
            ))
        }
    }

    /// Lo que hace cada botón sobre el panel que lo lleva.
    static func perform(_ button: Button, on pane: UIView) {
        guard let desktop = AppServices.shared.desktopViewController else { return }
        switch button {
        case .close:
            desktop.closePane(pane)
        case .minimize:
            desktop.minimizePane(pane)
        case .fullScreen:
            desktop.focus(pane)
            desktop.perform(.toggleFullScreen)
        }
    }
}
