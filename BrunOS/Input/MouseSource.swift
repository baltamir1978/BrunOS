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
/// del iPad. Esta vista ocupa la ventana del iPhone, recoge ese puntero y lo
/// convierte en desplazamientos relativos.
///
/// El puntero indirecto da posiciones absolutas dentro de la vista, así que hay
/// que derivar el movimiento restando la posición anterior. Efecto secundario
/// conocido: al llegar al borde de la pantalla del iPhone el puntero se queda
/// clavado y deja de haber desplazamiento. Se compensa recentrando la referencia
/// cuando se acerca al borde.
@MainActor
final class IndirectPointerSource: UIView, MouseSource, UIGestureRecognizerDelegate {

    weak var delegate: (any MouseSourceDelegate)?
    private(set) var isDelivering = false

    private var lastLocation: CGPoint?
    private lazy var hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
    private lazy var click = UITapGestureRecognizer(target: self, action: #selector(handleClick))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        hover.delegate = self
        pan.delegate = self
        pan.allowedScrollTypesMask = .all
        // Sólo el puntero indirecto: los dedos son para el trackpad de la
        // interfaz del iPhone, que es otra cosa.
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        click.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    func start() {
        addGestureRecognizer(hover)
        addGestureRecognizer(pan)
        addGestureRecognizer(click)
    }

    func stop() {
        [hover, pan, click].forEach(removeGestureRecognizer)
        isDelivering = false
        lastLocation = nil
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        let location = recognizer.location(in: self)
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
        // Con un ratón, `scrollType == .discrete` es la rueda; `.continuous`
        // es el gesto de dos dedos de un trackpad.
        if recognizer.numberOfTouches == 0 {
            let scroll = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
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
            lastLocation = recognizer.location(in: self)
            delegate?.mouseSource(self, didPress: .left)
        case .changed:
            emitTranslation(to: recognizer.location(in: self))
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
        let delta = CGVector(dx: location.x - previous.x, dy: location.y - previous.y)
        guard delta != .zero else { return }
        markDelivering()
        delegate?.mouseSource(self, didMove: MouseDelta(translation: delta, scroll: .zero))
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
