import QuartzCore
import UIKit

/// Ajustes de ratón que Bruno toca desde la interfaz del iPhone.
struct PointerSettings: Codable, Equatable, Sendable {

    /// Multiplica el desplazamiento que entrega la fuente.
    ///
    /// **Se multiplica con la velocidad de seguimiento de iOS**, la de
    /// Accesibilidad › Control del puntero. Conviene subir aquella y dejar ésta
    /// cerca de 1, porque lo que llega ya viene acelerado por el sistema; si se
    /// sube sólo ésta, el cursor da saltos.
    var sensitivity: Double = 1.0
    var scrollSpeed: Double = 1.0
    /// Scroll natural: el contenido sigue al dedo, como en macOS por defecto.
    var naturalScrolling: Bool = true

    static let key = "input.pointer"

    static func load(from defaults: UserDefaults = .standard) -> PointerSettings {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(PointerSettings.self, from: data)
        else { return PointerSettings() }
        return stored
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Elige sola entre las dos fuentes de ratón y reenvía lo que llegue.
///
/// Prefiere `GCMouse` porque da movimiento en bruto. Si `GCMouse` no entrega
/// nada pero el puntero indirecto sí, se pasa a él. La decisión no es de una vez
/// para siempre: se rehace cada vez que una fuente empieza o deja de entregar.
@MainActor
final class MouseRouter: MouseSourceDelegate {

    /// A quién le llegan los eventos ya elegidos.
    weak var delegate: (any MouseSourceDelegate)?

    private let gcSource = GCMouseSource()
    let indirectSource = IndirectPointerSource()

    /// Cuál está mandando ahora mismo, para poder rotularlo en los ajustes.
    private(set) var activeSourceName = "ninguna"

    func start() {
        gcSource.delegate = self
        indirectSource.delegate = self
        gcSource.start()
        indirectSource.start()
    }

    func stop() {
        gcSource.stop()
        indirectSource.stop()
    }

    /// La fuente que manda: GCMouse si entrega, si no el puntero indirecto.
    private var preferred: (any MouseSource)? {
        if gcSource.isDelivering { return gcSource }
        if indirectSource.isDelivering { return indirectSource }
        return nil
    }

    private func isActive(_ source: any MouseSource) -> Bool {
        preferred === source
    }

    func mouseSource(_ source: any MouseSource, didMove delta: MouseDelta) {
        guard isActive(source) else { return }
        delegate?.mouseSource(source, didMove: delta)
    }

    func mouseSource(_ source: any MouseSource, didPress button: PointerEvent.Button) {
        guard isActive(source) else { return }
        delegate?.mouseSource(source, didPress: button)
    }

    func mouseSource(_ source: any MouseSource, didRelease button: PointerEvent.Button) {
        guard isActive(source) else { return }
        delegate?.mouseSource(source, didRelease: button)
    }

    func mouseSourceDidChangeAvailability(_ source: any MouseSource) {
        activeSourceName = switch preferred {
        case let value as GCMouseSource where value === gcSource: "GCMouse"
        case let value as IndirectPointerSource where value === indirectSource: "puntero indirecto"
        default: "ninguna"
        }
        delegate?.mouseSourceDidChangeAvailability(source)
    }
}

/// El cursor de BrunOS: una capa encima de todo lo demás en la ventana externa.
///
/// El cursor se dibuja a mano porque **la pantalla externa no es interactiva** y
/// iOS no pinta ahí ningún puntero. Su posición se lleva en puntos lógicos del
/// escritorio, no en píxeles, para que sobreviva a los cambios de escala.
///
/// El repintado va contra el `CADisplayLink` **de la escena externa**, para
/// seguir su refresco y no el del iPhone. Ojo: en iOS 27
/// `UIScreen.displayLink(withTarget:selector:)` quedó obsoleto y hay que pedirlo
/// a `UIWindowScene`.
@MainActor
final class PointerController {

    /// Posición del cursor en puntos lógicos del escritorio.
    private(set) var position: CGPoint = .zero

    /// Límites del escritorio en puntos lógicos.
    var bounds: CGRect = .zero {
        didSet { clampIntoBounds() }
    }

    var settings = PointerSettings.load()

    private let layer = CALayer()
    private var displayLink: CADisplayLink?
    private var pendingPosition: CGPoint?
    private weak var hostLayer: CALayer?

    init() {
        buildCursor()
    }

    // MARK: - Instalación

    /// Coloca el cursor sobre la ventana externa y engancha el display link de
    /// su escena.
    func attach(to window: UIWindow) {
        hostLayer = window.layer
        window.layer.addSublayer(layer)
        layer.zPosition = 10_000

        displayLink?.invalidate()
        displayLink = window.windowScene?.displayLink(target: self, selector: #selector(step))
        displayLink?.add(to: .main, forMode: .common)
    }

    func detach() {
        displayLink?.invalidate()
        displayLink = nil
        layer.removeFromSuperlayer()
        hostLayer = nil
    }

    // MARK: - Movimiento

    /// Aplica un desplazamiento relativo. No repinta: eso lo hace el display
    /// link, para no dibujar más veces de las que la pantalla puede mostrar.
    func move(by delta: CGVector) {
        let next = CGPoint(
            x: position.x + delta.dx * settings.sensitivity,
            y: position.y + delta.dy * settings.sensitivity
        )
        position = clamp(next)
        pendingPosition = position
    }

    /// Recoloca el cursor dentro de la pantalla. Se llama al conectar un
    /// monitor, al cambiar de resolución y al cambiar la escala.
    func center() {
        position = CGPoint(x: bounds.midX, y: bounds.midY)
        pendingPosition = position
        step()
    }

    /// Convierte un scroll de la fuente al que espera el panel, aplicando
    /// velocidad y dirección.
    func scrollDelta(from raw: CGVector) -> CGVector {
        let sign: CGFloat = settings.naturalScrolling ? 1 : -1
        return CGVector(
            dx: raw.dx * settings.scrollSpeed * sign,
            dy: raw.dy * settings.scrollSpeed * sign
        )
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
    }

    private func clampIntoBounds() {
        position = clamp(position)
        pendingPosition = position
    }

    @objc private func step() {
        guard let pending = pendingPosition else { return }
        pendingPosition = nil
        // Sin animación implícita: si no, cada movimiento se interpola durante
        // un cuarto de segundo y el cursor va flotando por detrás del ratón.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = pending
        CATransaction.commit()
    }

    // MARK: - Dibujo

    /// Flecha sólida clara con reborde oscuro, para que se lea igual sobre el
    /// fondo casi negro del escritorio y sobre una página web blanca.
    private func buildCursor() {
        let size = CGSize(width: 14, height: 22)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 18))
        path.addLine(to: CGPoint(x: 4.4, y: 13.8))
        path.addLine(to: CGPoint(x: 7.2, y: 20.4))
        path.addLine(to: CGPoint(x: 10, y: 19.2))
        path.addLine(to: CGPoint(x: 7.2, y: 12.8))
        path.addLine(to: CGPoint(x: 12.6, y: 12.6))
        path.close()

        let shape = CAShapeLayer()
        shape.path = path.cgPath
        shape.fillColor = Tokens.Color.text.cgColor
        shape.strokeColor = UIColor.black.withAlphaComponent(0.85).cgColor
        shape.lineWidth = 1
        shape.lineJoin = .round

        layer.addSublayer(shape)
        layer.bounds = CGRect(origin: .zero, size: size)
        // El ancla en la punta: el cursor apunta con la esquina, no con su centro.
        layer.anchorPoint = CGPoint(x: 0, y: 0)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }
}
