import SwiftUI
import UIKit

/// View controller raíz de la escena del iPhone.
///
/// Es UIKit y no SwiftUI **a propósito**, por dos motivos que no tienen vuelta:
/// `registerSceneAccessory(_:)` es un método de `UIViewController`, y el teclado
/// físico sólo llega al first responder de esta ventana, nunca a la externa.
///
/// De modo que este objeto hace de centralita: registra el contenido externo,
/// se queda con el teclado y con el ratón, y reenvía todo al escritorio.
final class PhoneRootViewController: UIViewController {

    private let services = AppServices.shared
    private var host: UIHostingController<PhoneRootView>?
    private let onScreenKeyboard = OnScreenKeyboardField()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = Tokens.Color.background
        embedPhoneInterface()
        installPointerCapture()
        installOnScreenKeyboard()

        services.keyboard.delegate = self
        services.mouse.delegate = self
        services.start()

        // Aquí se declara el contenido de la pantalla externa. El sistema decide
        // cuándo presentarlo; la app tiene que funcionar igual sin monitor.
        services.externalDisplay.register(from: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    // MARK: - Cadena de responders

    override var canBecomeFirstResponder: Bool { true }

    /// Mete el `KeyboardRouter` en la cadena, justo por encima de este
    /// controlador. Así ve las teclas antes que nadie sin tener que heredar de
    /// él ni ensuciar esta clase con el reparto.
    override var next: UIResponder? {
        services.keyboard.nextInChain = super.next
        return services.keyboard
    }

    private func embedPhoneInterface() {
        let host = UIHostingController(rootView: PhoneRootView())
        host.view.backgroundColor = .clear

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host
    }

    /// El campo invisible que levanta el teclado del iPhone. Va detrás de todo
    /// para no robarle toques a nada.
    private func installOnScreenKeyboard() {
        onScreenKeyboard.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        view.insertSubview(onScreenKeyboard, at: 0)

        NotificationCenter.default.addObserver(
            forName: .brunosShowKeyboard,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.onScreenKeyboard.isFirstResponder {
                    self.onScreenKeyboard.resignFirstResponder()
                    // Al soltarlo, el teclado físico vuelve a encaminarse.
                    self.becomeFirstResponder()
                } else {
                    self.onScreenKeyboard.becomeFirstResponder()
                }
            }
        }
    }

    /// La vista que capta el puntero indirecto va **encima de todo** y sin
    /// fondo: tiene que ver pasar el puntero del ratón, pero dejar que los
    /// dedos lleguen al trackpad y a los botones de debajo.
    private func installPointerCapture() {
        let capture = services.mouse.indirectSource
        capture.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(capture)
        NSLayoutConstraint.activate([
            capture.topAnchor.constraint(equalTo: view.topAnchor),
            capture.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            capture.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            capture.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

// MARK: - Teclado

extension PhoneRootViewController: KeyboardRouterDelegate {

    func keyboardRouter(_ router: KeyboardRouter, didReceive command: DesktopCommand) -> Bool {
        services.desktopViewController?.perform(command) ?? false
    }

    func keyboardRouter(_ router: KeyboardRouter, didReceiveKey event: KeyEvent) {
        services.desktopViewController?.deliverKey(event)
    }
}

// MARK: - Ratón

extension PhoneRootViewController: MouseSourceDelegate {

    func mouseSource(_ source: any MouseSource, didMove delta: MouseDelta) {
        if delta.translation != .zero {
            services.pointer.move(by: delta.translation)
            services.desktopViewController?.deliverPointer(.moved, modifiers: [])
        }
        if delta.scroll != .zero {
            let scroll = services.pointer.scrollDelta(from: delta.scroll)
            services.desktopViewController?.deliverPointer(.scroll(delta: scroll), modifiers: [])
        }
    }

    func mouseSource(_ source: any MouseSource, didPress button: PointerEvent.Button) {
        services.desktopViewController?.deliverPointer(.down(button: button), modifiers: [])
    }

    func mouseSource(_ source: any MouseSource, didRelease button: PointerEvent.Button) {
        services.desktopViewController?.deliverPointer(.up(button: button), modifiers: [])
    }

    func mouseSourceDidChangeAvailability(_ source: any MouseSource) {
        services.assistiveTouch.refresh()
    }
}
