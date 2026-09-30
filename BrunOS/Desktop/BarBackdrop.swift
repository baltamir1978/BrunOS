import UIKit

/// Cuánto se transparentan el dock y la barra superior. Se elige en
/// Ajustes › General, cada uno por su lado (Bruno, 30-sep-2026).
enum BarTranslucency: Int, CaseIterable, Sendable {
    case opaque
    case low
    case medium
    case high

    var label: String {
        switch self {
        case .opaque: "Opaca"
        case .low: "Poca"
        case .medium: "Media"
        case .high: "Mucha"
        }
    }

    /// Cuánto tapa el tinte del color de los paneles, encima del desenfoque.
    /// `medium` es el dock de siempre (24-sep-2026).
    var tintAlpha: CGFloat {
        switch self {
        case .opaque: 1
        case .low: 0.7
        case .medium: 0.35
        case .high: 0.1
        }
    }

    /// El desenfoque de lo de detrás. Opaca no lleva: no se vería.
    var blurStyle: UIBlurEffect.Style? {
        switch self {
        case .opaque: nil
        case .low, .medium: .systemThinMaterial
        case .high: .systemUltraThinMaterial
        }
    }
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

    func apply(_ level: BarTranslucency) {
        blur.effect = level.blurStyle.map { UIBlurEffect(style: $0) }
        blur.isHidden = level.blurStyle == nil
        // Un color dinámico con otra opacidad sigue siendo dinámico: cambia
        // solo con el modo, sin pasar por `applyTheme`.
        tint.backgroundColor = fill.withAlphaComponent(level.tintAlpha)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        tint.frame = bounds
    }
}
