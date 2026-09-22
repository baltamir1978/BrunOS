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
    /// El toque es el del botón del ratón, no un dedo. Ver `touchesBegan`.
    private var isMouseButton = false

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

    /// **Con ratón, el toque es el botón.** AssistiveTouch no entrega el
    /// botón izquierdo como botón: lo convierte en un toque en la pantalla del
    /// iPhone, justo donde está su puntero. Mantener pulsado y mover es, para
    /// iOS, un dedo que se desliza.
    ///
    /// Antes ese toque se trataba como un dedo sobre el trackpad y se
    /// descartaba el movimiento, para no mover el cursor el doble: el clic
    /// suelto funcionaba, pero **arrastrar no hacía nada**. Ahora se trata
    /// como el ratón mismo: tocar es pulsar, mover es arrastrar y soltar es
    /// soltar.
    ///
    /// **El cursor no se coloca en el punto del toque**, sólo se desplaza lo
    /// que se desplace el toque. Una primera versión lo llevaba al punto del
    /// toque, suponiendo que caía justo bajo el puntero, y no es así: cada clic
    /// hacía saltar el cursor y arrastrar era imposible. El desplazamiento se
    /// escala como el del puntero, así que al soltar el cursor queda donde el
    /// puntero del iPhone lo vuelve a poner.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = event?.allTouches ?? touches
        lastPoint = centroid(of: all)
        isMouseButton = isFullScreen && services.assistiveTouch.isPointerWorking && all.count == 1
        guard isMouseButton else { return }
        services.pointer.isHoldingButton = true
        services.desktopViewController?.deliverPointer(.down(button: .left), modifiers: [])
    }

    /// Cuánto se mueve el cursor del monitor por cada punto del iPhone: lo mismo
    /// que con el puntero, cuyo recorrido es la pantalla entera.
    private var phoneToDesktop: CGSize {
        let desktop = services.pointer.bounds
        guard bounds.width > 0, bounds.height > 0, desktop.width > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: desktop.width / bounds.width, height: desktop.height / bounds.height)
    }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        // El clic ya se entregó al tocar: el toque y la pulsación larga
        // sobrarían, y harían dos clics.
        !isMouseButton
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = event?.allTouches ?? touches
        let point = centroid(of: all)
        defer { lastPoint = point }

        guard let previous = lastPoint else { return }

        if isMouseButton, all.count == 1 {
            let ratio = phoneToDesktop
            services.pointer.move(toDesktopDelta: CGVector(
                dx: (point.x - previous.x) * ratio.width,
                dy: (point.y - previous.y) * ratio.height
            ))
            services.desktopViewController?.deliverPointer(.moved, modifiers: [])
            return
        }

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
        releaseMouseButtonIfNeeded()
        finishDragIfNeeded()
        lastPoint = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        releaseMouseButtonIfNeeded()
        finishDragIfNeeded()
        lastPoint = nil
    }

    private func releaseMouseButtonIfNeeded() {
        guard isMouseButton else { return }
        isMouseButton = false
        services.pointer.isHoldingButton = false
        // El clic es del ratón: cuenta como señal de vida. Con cada clic el
        // «hover» termina un instante y, sin esto, un ratón quieto después de
        // hacer clic se daba por desconectado a los tres segundos.
        services.assistiveTouch.notePointerEvent()
        services.desktopViewController?.deliverPointer(.up(button: .left), modifiers: [])
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
