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
        installOnScreenKeyboard()

        // El puntero indirecto escucha sobre esta misma vista. No se le pone
        // una vista propia encima: taparía los toques de la interfaz.
        services.mouse.indirectSource.attach(to: view)

        // El escritorio sigue el modo del iPhone, y el único sitio donde se
        // sabe cuál es de verdad es aquí.
        DesktopTheme.phoneStyle = traitCollection.userInterfaceStyle
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: Self, _) in
            DesktopTheme.phoneStyle = controller.traitCollection.userInterfaceStyle
        }

        services.keyboard.delegate = self
        services.mouse.delegate = self
        services.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(restoreKeyboard),
            name: .brunosRestoreKeyboard,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(externalDisplayChanged),
            name: ExternalDisplayManager.didChangeNotification,
            object: nil
        )

        // Aquí se declara el contenido de la pantalla externa. El sistema decide
        // cuándo presentarlo; la app tiene que funcionar igual sin monitor.
        services.externalDisplay.register(from: self)
    }

    /// **Al quitar el cable, iOS no siempre desconecta la escena externa
    /// enseguida**: puede dejarla en segundo plano un buen rato, y mientras
    /// tanto `sceneDidDisconnect` no llega. El iPhone se quedaba en modo mando,
    /// en negro, sin monitor delante.
    ///
    /// La fuente fiable es la del propio accesorio: `isAvailable` dice si el
    /// sistema puede mostrarlo, y UIKit vuelve a llamar aquí cada vez que
    /// cambia, porque se lee dentro de `updateProperties`.
    override func updateProperties() {
        super.updateProperties()
        let manager = services.externalDisplay
        guard let registration = manager.registration else { return }
        if !registration.isAvailable, manager.currentProfile != nil {
            EventLog.note("Monitor: el accesorio deja de estar disponible")
            manager.detach()
        } else if registration.isAvailable, manager.currentProfile == nil {
            // Vuelve a estar disponible y la escena sigue viva: si iOS no
            // conecta una nueva, hay que engancharla otra vez (ver
            // `ExternalSceneDelegate.reattachIfNeeded`).
            ExternalSceneDelegate.reattachAll()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    @objc private func restoreKeyboard() {
        // Tras cerrarse la hoja: si se pide antes, el campo de la hoja todavía
        // es el primer respondedor y se lo vuelve a quedar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.becomeFirstResponder()
        }
    }

    /// Al conectar el monitor, el iPhone vuelve a su pantalla de mando.
    ///
    /// SwiftUI cierra su hoja de ajustes por su cuenta (ver `PhoneRootView`),
    /// pero puede haber algo más presentado encima —el asistente de
    /// AssistiveTouch, un selector— y cualquier cosa ahí se queda con los
    /// toques. Lo único que se respeta es el selector de carpetas: si está
    /// abierto es porque se ha pedido desde el propio monitor.
    ///
    /// Y hay que recuperar el primer respondedor, que se lo había llevado la
    /// hoja: sin él, el teclado físico no llega a ninguna parte.
    @objc private func externalDisplayChanged() {
        guard services.externalDisplay.currentProfile != nil else { return }
        guard let presented = presentedViewController,
              !(presented is UIDocumentPickerViewController),
              !services.passwords.isAsking
        else {
            becomeFirstResponder()
            return
        }
        dismiss(animated: true) { [weak self] in
            self?.becomeFirstResponder()
        }
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
}

// MARK: - Teclado

extension PhoneRootViewController: KeyboardRouterDelegate {

    func keyboardRouter(_ router: KeyboardRouter, didReceive command: DesktopCommand) -> Bool {
        services.desktopViewController?.performShortcut(command) ?? false
    }

    func keyboardRouter(_ router: KeyboardRouter, didReceiveKey event: KeyEvent) {
        services.desktopViewController?.deliverKey(event)
    }
}

// MARK: - Ratón

extension PhoneRootViewController: MouseSourceDelegate {

    func mouseSource(_ source: any MouseSource, didMove delta: MouseDelta) {
        if let position = delta.position {
            guard !services.pointer.isHoldingButton else { return }
            services.pointer.move(toNormalized: position)
            services.desktopViewController?.deliverPointer(.moved, modifiers: [])
        } else if delta.translation != .zero {
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
