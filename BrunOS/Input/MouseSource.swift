import GameController
import UIKit

/// Movimiento de ratón ya normalizado, venga de donde venga.
///
/// Siempre **relativo**: BrunOS lleva su propio cursor en coordenadas lógicas de
/// la pantalla externa, así que nunca le sirve una posición absoluta del iPhone.
struct MouseDelta {
    /// Desplazamiento en puntos, con la y hacia abajo.
    var translation: CGVector
    var scroll: CGVector
}

@MainActor
protocol MouseSourceDelegate: AnyObject {
    func mouseSource(_ source: any MouseSource, didMove delta: MouseDelta)
    func mouseSource(_ source: any MouseSource, didPress button: PointerEvent.Button)
    func mouseSource(_ source: any MouseSource, didRelease button: PointerEvent.Button)
    /// Avisa de si la fuente está recibiendo eventos de verdad, para que
    /// `MouseRouter` pueda cambiarse a la otra.
    func mouseSourceDidChangeAvailability(_ source: any MouseSource)
}

@MainActor
protocol MouseSource: AnyObject {
    var delegate: (any MouseSourceDelegate)? { get set }
    /// Si esta fuente está entregando eventos ahora mismo.
    var isDelivering: Bool { get }
    func start()
    func stop()
}

// MARK: - GCMouse

/// Ratón por el framework GameController: movimiento en bruto, botones y rueda.
///
/// Es la fuente preferida porque entrega desplazamiento crudo, sin que iOS le
/// aplique su aceleración. El problema es que en iPhone **no siempre entrega
/// nada**: el ratón Bluetooth va por AssistiveTouch, y según la configuración
/// los eventos no llegan aquí. Por eso existe la otra fuente y un enrutador que
/// elige sola.
@MainActor
final class GCMouseSource: NSObject, MouseSource {

    weak var delegate: (any MouseSourceDelegate)?
    private(set) var isDelivering = false
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        // Las cabeceras las declaran como `NSString *const`, pero Swift las
        // reexpone renombradas como miembros de `Notification.Name`, sin el
        // sufijo "Notification". Escribirlas como en el header no compila.
        let connected: [Notification.Name] = [
            .GCMouseDidConnect,
            .GCMouseDidBecomeCurrent,
        ]
        for name in connected {
            // No se toca el `Notification` que llega: no es `Sendable` y en
            // Swift 6 estricto sacarlo de aquí es un error de concurrencia.
            // Da igual, porque lo que interesa es el ratón que manda ahora.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.bind(GCMouse.current)
                }
            })
        }
        observers.append(center.addObserver(
            forName: .GCMouseDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isDelivering = false
                self.delegate?.mouseSourceDidChangeAvailability(self)
            }
        })

        bind(GCMouse.current)
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        GCMouse.current?.mouseInput?.mouseMovedHandler = nil
        isDelivering = false
    }

    private func bind(_ mouse: GCMouse?) {
        guard let input = mouse?.mouseInput else { return }

        input.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.isDelivering {
                    self.isDelivering = true
                    self.delegate?.mouseSourceDidChangeAvailability(self)
                }
                // GameController da la y hacia arriba; el escritorio la quiere
                // hacia abajo, como todas las coordenadas de UIKit.
                self.delegate?.mouseSource(self, didMove: MouseDelta(
                    translation: CGVector(dx: CGFloat(deltaX), dy: CGFloat(-deltaY)),
                    scroll: .zero
                ))
            }
        }

        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.report(.left, pressed: pressed) }
        }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.report(.right, pressed: pressed) }
        }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.report(.middle, pressed: pressed) }
        }

        input.scroll.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.mouseSource(self, didMove: MouseDelta(
                    translation: .zero,
                    scroll: CGVector(dx: CGFloat(x), dy: CGFloat(y))
                ))
            }
        }
    }

    private func report(_ button: PointerEvent.Button, pressed: Bool) {
        if pressed {
            delegate?.mouseSource(self, didPress: button)
        } else {
            delegate?.mouseSource(self, didRelease: button)
        }
    }
}

// MARK: - Puntero indirecto

/// Alternativa cuando `GCMouse` no entrega nada.
///
/// En el iPhone el ratón Bluetooth funciona a través de AssistiveTouch, y lo que
/// llega a la app es un **puntero indirecto** de UIKit, el mismo que el trackpad
/// del iPad. Esta clase recoge ese puntero y lo convierte en desplazamientos
/// relativos.
///
/// **No es una vista, y eso importa.** La primera versión sí lo era: una UIView
/// transparente a pantalla completa por encima de la interfaz. Aunque sus gestos
/// filtraban por tipo de toque, la vista seguía ganando el hit test y **se comía
/// todos los toques del dedo**: los botones de debajo dejaron de responder.
///
/// Ahora los reconocedores se instalan sobre la vista raíz que ya existe, con
/// `cancelsTouchesInView = false`, de modo que el dedo sigue llegando a SwiftUI
/// y el puntero se capta igual.
///
/// El puntero indirecto da posiciones absolutas dentro de la vista, así que hay
/// que derivar el movimiento restando la posición anterior.
@MainActor
final class IndirectPointerSource: NSObject, MouseSource, UIGestureRecognizerDelegate {

    weak var delegate: (any MouseSourceDelegate)?
    private(set) var isDelivering = false

    /// Vista sobre la que se escucha. Es la raíz de la escena del iPhone, no
    /// una vista propia.
    private weak var host: UIView?

    private var lastLocation: CGPoint?
    private lazy var hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
    private lazy var click = UITapGestureRecognizer(target: self, action: #selector(handleClick))

    /// Hay que llamarlo antes que `start()`.
    func attach(to view: UIView) {
        host = view
    }

    func start() {
        guard let host else { return }

        for recognizer in [hover, pan, click] as [UIGestureRecognizer] {
            recognizer.delegate = self
            // Sin esto, reconocer el gesto cancelaría el toque a la vista de
            // debajo y volveríamos al problema de los botones muertos.
            recognizer.cancelsTouchesInView = false
            host.addGestureRecognizer(recognizer)
        }

        pan.allowedScrollTypesMask = .all
        // Sólo el puntero indirecto: los dedos son para el trackpad de la
        // interfaz del iPhone, que es otra cosa.
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        click.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
    }

    func stop() {
        guard let host else { return }
        [hover, pan, click].forEach(host.removeGestureRecognizer)
        isDelivering = false
        lastLocation = nil
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard let host else { return }
        let location = recognizer.location(in: host)
        switch recognizer.state {
        case .began:
            lastLocation = location
            markDelivering()
        case .changed:
            emitTranslation(to: location)
        case .ended, .cancelled:
            lastLocation = nil
        default:
            break
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let host else { return }

        // Con un ratón, un pan sin dedos encima es la rueda.
        if recognizer.numberOfTouches == 0 {
            let scroll = recognizer.translation(in: host)
            recognizer.setTranslation(.zero, in: host)
            if scroll != .zero {
                markDelivering()
                delegate?.mouseSource(self, didMove: MouseDelta(
                    translation: .zero,
                    scroll: CGVector(dx: scroll.x, dy: scroll.y)
                ))
            }
            return
        }

        // Arrastre con el botón pulsado.
        switch recognizer.state {
        case .began:
            lastLocation = recognizer.location(in: host)
            delegate?.mouseSource(self, didPress: .left)
        case .changed:
            emitTranslation(to: recognizer.location(in: host))
        case .ended, .cancelled:
            delegate?.mouseSource(self, didRelease: .left)
            lastLocation = nil
        default:
            break
        }
    }

    @objc private func handleClick(_ recognizer: UITapGestureRecognizer) {
        delegate?.mouseSource(self, didPress: .left)
        delegate?.mouseSource(self, didRelease: .left)
    }

    private func emitTranslation(to location: CGPoint) {
        defer { lastLocation = location }
        guard let previous = lastLocation else { return }

        var delta = CGVector(dx: location.x - previous.x, dy: location.y - previous.y)
        guard delta != .zero else { return }

        // El recorrido disponible es la pantalla del iPhone, que es **más
        // pequeña que el escritorio**: 852 pt de alto contra 960 lógicos en un
        // monitor 2K a escala 1,5. Trasladando el movimiento 1:1, recorrer el
        // teléfono entero no llegaba a cruzar la pantalla y el cursor se
        // plantaba al tocar el borde, sobre todo hacia arriba.
        //
        // Se compensa con la razón entre los dos tamaños, de modo que un
        // barrido completo del iPhone cubra el escritorio completo.
        let ratio = desktopToHostRatio()
        delta.dx *= ratio.width
        delta.dy *= ratio.height

        markDelivering()
        delegate?.mouseSource(self, didMove: MouseDelta(translation: delta, scroll: .zero))
    }

    private func desktopToHostRatio() -> CGSize {
        guard let host, host.bounds.width > 0, host.bounds.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let desktop = AppServices.shared.pointer.bounds
        guard desktop.width > 0, desktop.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        return CGSize(
            width: desktop.width / host.bounds.width,
            height: desktop.height / host.bounds.height
        )
    }

    private func markDelivering() {
        guard !isDelivering else { return }
        isDelivering = true
        delegate?.mouseSourceDidChangeAvailability(self)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
