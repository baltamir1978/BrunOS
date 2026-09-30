import UIKit

/// Cuánto se transparentan el dock y la barra superior: de 0 (opaca) a 1 (lo
/// máximo). Se elige en Ajustes › General con un deslizador, cada uno por su
/// lado (Bruno, 30-sep-2026; antes eran cuatro niveles fijos).
enum BarTransparency {
    /// Cuánto tapa el tinte del color de los paneles, encima del desenfoque.
    /// A 0,72 es el dock de siempre (24-sep-2026).
    static func tintAlpha(_ amount: Double) -> CGFloat {
        1 - 0.9 * CGFloat(min(max(amount, 0), 1))
    }

    /// Los cuatro niveles de antes (Opaca, Poca, Media, Mucha), para recoger lo
    /// que hubiera guardado: dan el mismo tinte que daban.
    static let legacyLevels: [Double] = [0, 1.0 / 3, 0.65 / 0.9, 1]
}

/// El fondo del dock y de la barra superior: desenfoque del sistema y, encima,
/// un tinte del color de los paneles para que el texto y los iconos no se
/// pierdan sobre un fondo claro.
///
/// `applyContentsScale` y `redraw` no entran en el `UIVisualEffectView`: el
/// sistema compone sus capas a su manera.
@MainActor
final class BarBackdrop: UIView {

    private let blur = UIVisualEffectView(effect: nil)
    private let tint = UIView()
    private let fill: UIColor

    init(fill: UIColor, cornerRadius: CGFloat = 0) {
        self.fill = fill
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.cornerRadius = cornerRadius
        clipsToBounds = true
        addSubview(blur)
        addSubview(tint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    func apply(_ amount: Double) {
        // Un solo material para todo el recorrido: cambiarlo a mitad se veía
        // como un salto al mover el deslizador. Opaca no lleva: no se vería.
        let opaque = amount <= 0.001
        if !opaque, blur.effect == nil { blur.effect = UIBlurEffect(style: .systemThinMaterial) }
        blur.isHidden = opaque
        // Un color dinámico con otra opacidad sigue siendo dinámico: cambia
        // solo con el modo, sin pasar por `applyTheme`.
        tint.backgroundColor = fill.withAlphaComponent(BarTransparency.tintAlpha(amount))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        tint.frame = bounds
    }
}
