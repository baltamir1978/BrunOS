import SwiftUI
import UIKit

/// Trackpad de emergencia: mueve el cursor del escritorio con el dedo.
///
/// Es la salida cuando no hay ratón a mano, o cuando AssistiveTouch está
/// apagado y el ratón Bluetooth todavía no responde. No pretende sustituir al
/// ratón, sólo permitir apañarse.
///
/// Se hace con UIKit y no con los gestos de SwiftUI porque aquí hace falta
/// distinguir el número de dedos y el tipo de toque, y en SwiftUI eso no se
/// puede mirar.
struct TrackpadView: UIViewRepresentable {

    var isFullScreen = false

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.isFullScreen = isFullScreen
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {
        uiView.isFullScreen = isFullScreen
    }
}

@MainActor
final class TrackpadUIView: UIView {

    private let services = AppServices.shared
    private var lastPoint: CGPoint?
    private var isDragging = false

    /// Cuánto se multiplica el dedo. Por debajo de 1 el cursor se queda corto
    /// en un monitor grande; por encima de 2 se vuelve imposible apuntar.
    private let gain: CGFloat = 1.6

    /// A pantalla completa pierde el marco: ya no es un recuadro, es el fondo.
    var isFullScreen = false {
        didSet {
            layer.cornerRadius = isFullScreen ? 0 : Tokens.Metric.paneCornerRadius
            layer.borderWidth = isFullScreen ? 0 : 1
            backgroundColor = isFullScreen ? Tokens.Color.background : Tokens.Color.panel
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Tokens.Color.panel
        layer.cornerRadius = Tokens.Metric.paneCornerRadius
        layer.borderWidth = 1
        layer.borderColor = Tokens.Color.border.cgColor
        // Con el trackpad a pantalla completa, las esquinas redondeadas y el
        // borde sobran: se quitan desde fuera con `fullScreen`.
        isMultipleTouchEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.35
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(longPress)

        isAccessibilityElement = true
        accessibilityLabel = "Trackpad"
        accessibilityHint = "Desliza para mover el puntero. Toca para hacer clic. "
            + "Dos dedos para desplazar."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    // MARK: - Dedos

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastPoint = centroid(of: event?.allTouches ?? touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = event?.allTouches ?? touches
        let point = centroid(of: all)
        defer { lastPoint = point }
        guard let previous = lastPoint else { return }

        let delta = CGVector(
            dx: (point.x - previous.x) * gain,
            dy: (point.y - previous.y) * gain
        )

        // Con ratón conectado y el trackpad a pantalla completa, el dedo no
        // mueve el cursor: lo que llega no es un dedo de verdad, es el toque
        // que AssistiveTouch genera bajo el puntero. Moverlo aquí además lo
        // desplazaría el doble.
        if isFullScreen, services.assistiveTouch.isPointerWorking, all.count < 2 {
            return
        }

        if all.count >= 2 {
            // Dos dedos: desplazar el contenido del panel bajo el cursor.
            let scroll = services.pointer.scrollDelta(from: delta)
            services.desktopViewController?.deliverPointer(.scroll(delta: scroll), modifiers: [])
        } else {
            services.pointer.move(by: delta)
            services.desktopViewController?.deliverPointer(.moved, modifiers: [])
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishDragIfNeeded()
        lastPoint = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishDragIfNeeded()
        lastPoint = nil
    }

    private func centroid(of touches: Set<UITouch>) -> CGPoint {
        guard !touches.isEmpty else { return .zero }
        let sum = touches.reduce(CGPoint.zero) { partial, touch in
            let location = touch.location(in: self)
            return CGPoint(x: partial.x + location.x, y: partial.y + location.y)
        }
        return CGPoint(x: sum.x / CGFloat(touches.count), y: sum.y / CGFloat(touches.count))
    }

    // MARK: - Clic y arrastre

    @objc private func handleTap() {
        services.desktopViewController?.deliverPointer(.down(button: .left), modifiers: [])
        services.desktopViewController?.deliverPointer(.up(button: .left), modifiers: [])
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Mantener pulsado deja el botón apretado para poder arrastrar: seleccionar
    /// texto en el terminal, mover un divisor del mosaico o arrastrar un fichero.
    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isDragging = true
            services.desktopViewController?.deliverPointer(.down(button: .left), modifiers: [])
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .ended, .cancelled, .failed:
            finishDragIfNeeded()
        default:
            break
        }
    }

    private func finishDragIfNeeded() {
        guard isDragging else { return }
        isDragging = false
        services.desktopViewController?.deliverPointer(.up(button: .left), modifiers: [])
    }
}
