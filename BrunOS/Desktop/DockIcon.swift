import UIKit

/// Iconos del dock, dibujados por código.
///
/// **No son los de macOS.** Los iconos de Apple tienen derechos y no se pueden
/// copiar a un repositorio público, así que estos están dibujados a mano
/// inspirándose en lo que cada uno significa: la consola negra con el prompt,
/// la brújula del navegador y la carpeta de los ficheros. Se reconocen igual y
/// son nuestros.
///
/// Se generan como `UIImage` y se cachean: dibujar tres iconos en cada pasada
/// de layout sería tirar tiempo.
@MainActor
enum DockIcon {

    /// Caché de lo ya dibujado. Vive en el actor principal, que es desde donde
    /// se pinta el dock, y así Swift 6 no protesta por estado global mutable.
    private static var cache: [String: UIImage] = [:]

    static func image(for kind: PaneKind, size: CGFloat) -> UIImage {
        let key = "\(kind.rawValue)-\(Int(size))"
        if let cached = cache[key] { return cached }
        let image = render(size: size) { context, rect in
            switch kind {
            case .terminal: drawTerminal(context, rect)
            case .browser: drawCompass(context, rect)
            case .files: drawFolder(context, rect)
            }
        }
        cache[key] = image
        return image
    }

    static func settingsImage(size: CGFloat) -> UIImage {
        let key = "settings-\(Int(size))"
        if let cached = cache[key] { return cached }
        let image = render(size: size) { context, rect in drawGear(context, rect) }
        cache[key] = image
        return image
    }

    private static func render(
        size: CGFloat,
        draw: (CGContext, CGRect) -> Void
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            draw(context.cgContext, CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    /// Fondo de cuadrado redondeado, como cualquier icono de app.
    private static func roundedBackground(
        _ context: CGContext,
        _ rect: CGRect,
        colors: [UIColor]
    ) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.width * 0.23)
        context.saveGState()
        context.addPath(path.cgPath)
        context.clip()

        if colors.count > 1,
           let gradient = CGGradient(
               colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors.map(\.cgColor) as CFArray,
               locations: [0, 1]
           ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.midX, y: rect.minY),
                end: CGPoint(x: rect.midX, y: rect.maxY),
                options: []
            )
        } else {
            context.setFillColor(colors[0].cgColor)
            context.fill(rect)
        }
        context.restoreGState()
    }

    /// Consola: fondo casi negro con el prompt `>_` en ámbar.
    private static func drawTerminal(_ context: CGContext, _ rect: CGRect) {
        roundedBackground(context, rect, colors: [
            UIColor(hex: 0x3A3F47), UIColor(hex: 0x14171B),
        ])

        let inset = rect.width * 0.2
        context.setStrokeColor(UIColor(hex: 0xE8A33D).cgColor)
        context.setLineWidth(rect.width * 0.075)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // El chevron del prompt.
        let top = rect.minY + inset * 1.15
        let bottom = rect.midY + rect.height * 0.04
        context.move(to: CGPoint(x: inset, y: top))
        context.addLine(to: CGPoint(x: rect.midX - rect.width * 0.06, y: (top + bottom) / 2))
        context.addLine(to: CGPoint(x: inset, y: bottom))
        context.strokePath()

        // El guion bajo del cursor.
        context.setStrokeColor(UIColor(hex: 0xE6E3DC).cgColor)
        context.move(to: CGPoint(x: rect.midX + rect.width * 0.02, y: bottom))
        context.addLine(to: CGPoint(x: rect.maxX - inset, y: bottom))
        context.strokePath()
    }

    /// Brújula: azul con la aguja bicolor, como se entiende un navegador.
    private static func drawCompass(_ context: CGContext, _ rect: CGRect) {
        roundedBackground(context, rect, colors: [
            UIColor(hex: 0x3AA0F5), UIColor(hex: 0x1662C4),
        ])

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width * 0.3

        context.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(rect.width * 0.045)
        context.addArc(
            center: center, radius: radius,
            startAngle: 0, endAngle: .pi * 2, clockwise: false
        )
        context.strokePath()

        // La aguja: mitad roja hacia arriba, mitad clara hacia abajo.
        let needle = radius * 0.72
        let width = radius * 0.26
        let angle = -CGFloat.pi / 4

        func point(_ distance: CGFloat, _ rotation: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + cos(angle + rotation) * distance,
                y: center.y + sin(angle + rotation) * distance
            )
        }

        context.setFillColor(UIColor(hex: 0xFF5A52).cgColor)
        context.move(to: point(needle, 0))
        context.addLine(to: point(width, .pi / 2))
        context.addLine(to: point(width, -.pi / 2))
        context.closePath()
        context.fillPath()

        context.setFillColor(UIColor.white.cgColor)
        context.move(to: point(needle, .pi))
        context.addLine(to: point(width, .pi / 2))
        context.addLine(to: point(width, -.pi / 2))
        context.closePath()
        context.fillPath()
    }

    /// Carpeta azul, con la pestaña de arriba.
    private static func drawFolder(_ context: CGContext, _ rect: CGRect) {
        roundedBackground(context, rect, colors: [
            UIColor(hex: 0x6FC4FF), UIColor(hex: 0x2A86D8),
        ])

        let inset = rect.width * 0.19
        let body = CGRect(
            x: inset, y: rect.midY - rect.height * 0.16,
            width: rect.width - inset * 2, height: rect.height * 0.34
        )

        // La pestaña, un poco más estrecha y por encima del cuerpo.
        let tab = CGRect(
            x: inset, y: body.minY - rect.height * 0.09,
            width: body.width * 0.45, height: rect.height * 0.12
        )
        context.setFillColor(UIColor.white.withAlphaComponent(0.75).cgColor)
        context.addPath(UIBezierPath(roundedRect: tab, cornerRadius: rect.width * 0.035).cgPath)
        context.fillPath()

        context.setFillColor(UIColor.white.cgColor)
        context.addPath(UIBezierPath(roundedRect: body, cornerRadius: rect.width * 0.05).cgPath)
        context.fillPath()
    }

    /// Engranaje de los ajustes.
    private static func drawGear(_ context: CGContext, _ rect: CGRect) {
        roundedBackground(context, rect, colors: [
            UIColor(hex: 0x6E757F), UIColor(hex: 0x3C424B),
        ])

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = rect.width * 0.3
        let inner = rect.width * 0.14

        context.setFillColor(UIColor.white.cgColor)
        // Ocho dientes alrededor.
        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4
            let tooth = CGRect(
                x: center.x + cos(angle) * outer - rect.width * 0.05,
                y: center.y + sin(angle) * outer - rect.width * 0.05,
                width: rect.width * 0.1,
                height: rect.width * 0.1
            )
            context.addPath(UIBezierPath(roundedRect: tooth, cornerRadius: rect.width * 0.02).cgPath)
        }
        context.fillPath()

        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(rect.width * 0.09)
        context.addArc(
            center: center, radius: (outer + inner) / 2,
            startAngle: 0, endAngle: .pi * 2, clockwise: false
        )
        context.strokePath()

        // El agujero del centro.
        context.setBlendMode(.clear)
        context.addArc(
            center: center, radius: inner * 0.75,
            startAngle: 0, endAngle: .pi * 2, clockwise: false
        )
        context.fillPath()
        context.setBlendMode(.normal)
    }
}
