import SwiftUI
import UIKit

/// View controller raíz de la escena del iPhone.
///
/// Es UIKit y no SwiftUI **a propósito**: `registerSceneAccessory(_:)` es un
/// método de `UIViewController`, y el prompt pide la versión UIKit del accesorio
/// de escena. La interfaz de dentro sí es SwiftUI, embebida en un
/// `UIHostingController`.
///
/// Más adelante esta clase será también el primer responder del teclado físico
/// (`KeyboardRouter`, Fase 1): la escena externa no es interactiva, así que las
/// teclas entran por aquí.
final class PhoneRootViewController: UIViewController {

    private let externalDisplay: ExternalDisplayManager

    init(externalDisplay: ExternalDisplayManager) {
        self.externalDisplay = externalDisplay
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = Tokens.Color.background
        embedPhoneInterface()

        // Aquí se declara el contenido de la pantalla externa. El sistema decide
        // cuándo presentarlo; la app tiene que funcionar igual sin monitor.
        externalDisplay.register(from: self)
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
    }
}
