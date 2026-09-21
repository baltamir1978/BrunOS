import GameController
import Observation
import UIKit

/// Vigila AssistiveTouch y sabe pedirle a Atajos que lo encienda.
///
/// **Por qué existe todo esto.** En el iPhone un ratón Bluetooth sólo funciona
/// con AssistiveTouch activado, y **ninguna app puede activarlo por API**: no
/// hay forma pública de hacerlo, ni la va a haber. Tampoco se pueden crear
/// automatizaciones de Atajos desde una app, ni importarlas.
///
/// Lo único que sí se puede hacer es **ejecutar** un atajo que ya exista, con
/// `shortcuts://x-callback-url/run-shortcut`. De ahí sale el diseño: Bruno crea
/// una vez el atajo y las automatizaciones a mano, guiado por un asistente, y a
/// partir de entonces BrunOS puede encender AssistiveTouch con un botón.
@MainActor
@Observable
final class AssistiveTouchMonitor {

    /// Nombre del atajo que activa AssistiveTouch, configurable en ajustes.
    static let shortcutNameKey = "assistiveTouch.shortcutName"
    static let defaultShortcutName = "BrunOS AssistiveTouch"

    /// Si AssistiveTouch está encendido ahora mismo.
    private(set) var isRunning = UIAccessibility.isAssistiveTouchRunning
    /// Si hay un ratón emparejado y visible para GameController.
    private(set) var hasMouse = GCMouse.current != nil
    /// Si hay una pantalla externa conectada.
    var hasExternalDisplay = false

    /// Qué pasó la última vez que se intentó ejecutar el atajo.
    ///
    /// Sin esto, el botón «Activar» abre Atajos, vuelve y **no dice nada**, que
    /// es indistinguible de que el atajo no exista. Los tres casos se arreglan
    /// de forma distinta y hay que poder separarlos.
    enum Attempt: Equatable {
        /// Volvió bien y AssistiveTouch quedó encendido.
        case worked
        /// Atajos dijo que sí, pero AssistiveTouch sigue apagado: el atajo
        /// existe y no hace lo que debería.
        case ranButNothingChanged
        /// Atajos devolvió error, casi siempre porque no hay ningún atajo con
        /// ese nombre.
        case failed
        /// No se pudo ni abrir Atajos.
        case couldNotOpen

        var message: String {
            switch self {
            case .worked:
                "AssistiveTouch activado."
            case .ranButNothingChanged:
                "El atajo se ejecutó, pero AssistiveTouch sigue apagado. "
                    + "Comprueba que su acción sea «Establecer AssistiveTouch» puesta en activar."
            case .failed:
                "Atajos no pudo ejecutarlo. Lo más probable es que no exista "
                    + "ningún atajo con ese nombre exacto."
            case .couldNotOpen:
                "No se pudo abrir Atajos."
            }
        }

        var isGood: Bool { self == .worked }
    }

    private(set) var lastAttempt: Attempt?

    private var observers: [NSObjectProtocol] = []

    var shortcutName: String {
        get {
            UserDefaults.standard.string(forKey: Self.shortcutNameKey)
                ?? Self.defaultShortcutName
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.shortcutNameKey)
        }
    }

    /// Cuándo merece la pena dar la lata con el aviso.
    ///
    /// Sólo si hace falta de verdad: hay monitor o ratón, y AssistiveTouch está
    /// apagado. Sin nada conectado, el aviso sería ruido.
    var shouldWarn: Bool {
        !isRunning && (hasExternalDisplay || hasMouse)
    }

    func start() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: UIAccessibility.assistiveTouchStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isRunning = UIAccessibility.isAssistiveTouchRunning
            }
        })

        for name: Notification.Name in [.GCMouseDidConnect, .GCMouseDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hasMouse = GCMouse.current != nil
                }
            })
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Refresca el estado al volver de Atajos, que es justo cuando ha podido
    /// cambiar sin que llegara la notificación.
    func refresh() {
        isRunning = UIAccessibility.isAssistiveTouchRunning
        hasMouse = GCMouse.current != nil
    }

    /// Gestiona la vuelta desde Atajos por `brunos://`.
    ///
    /// Al volver de otra app, `isAssistiveTouchRunning` puede tardar un
    /// instante en reflejar el cambio, así que se vuelve a mirar un poco
    /// después antes de dar nada por fallido.
    func handleCallback(host: String?) {
        guard host == "assistivetouch-ok" else {
            if host == "assistivetouch-error" { lastAttempt = .failed }
            return
        }

        refresh()
        if isRunning {
            lastAttempt = .worked
            return
        }

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self else { return }
            self.refresh()
            self.lastAttempt = self.isRunning ? .worked : .ranButNothingChanged
        }
    }

    /// Lanza el atajo y deja anotado el resultado.
    func runShortcut() {
        lastAttempt = nil
        open(runShortcutURL) { [weak self] in
            self?.lastAttempt = .couldNotOpen
        }
    }

    // MARK: - Atajos

    /// URL que ejecuta el atajo y vuelve a BrunOS al terminar.
    ///
    /// El `x-success` es lo que hace que no haya que volver a mano desde Atajos.
    var runShortcutURL: URL? {
        var components = URLComponents(string: "shortcuts://x-callback-url/run-shortcut")
        components?.queryItems = [
            URLQueryItem(name: "name", value: shortcutName),
            URLQueryItem(name: "x-success", value: "brunos://assistivetouch-ok"),
            URLQueryItem(name: "x-error", value: "brunos://assistivetouch-error"),
        ]
        return components?.url
    }

    static let shortcutsAppURL = URL(string: "shortcuts://")

    /// Abre una URL sin preguntar antes si se puede.
    ///
    /// `canOpenURL` quedó obsoleto en iOS 27 y la recomendación de Apple es
    /// exactamente ésta: intentarlo y gestionar el fallo. Aquí un fallo
    /// significa, casi siempre, que el atajo no existe todavía.
    func open(_ url: URL?, onFailure: @escaping () -> Void) {
        guard let url else {
            onFailure()
            return
        }
        UIApplication.shared.open(url, options: [:]) { succeeded in
            MainActor.assumeIsolated {
                if !succeeded { onFailure() }
            }
        }
    }
}

/// Pasos del asistente de configuración, con la casilla que marca Bruno.
///
/// El estado de las casillas es suyo, no deducido: BrunOS **no puede** saber si
/// una automatización de Atajos existe. Lo único que sí sabe es si
/// AssistiveTouch está activo, y con eso se rotula "Configurado" cuando lo
/// observado coincide con lo que debería pasar.
enum AssistiveTouchStep: String, CaseIterable, Identifiable {
    case createShortcut
    case automationOnOpen
    case automationOnClose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .createShortcut: "Crear el atajo"
        case .automationOnOpen: "Automatizar al abrir"
        case .automationOnClose: "Automatizar al cerrar"
        }
    }

    var detail: String {
        switch self {
        case .createShortcut:
            "En Atajos, crea uno llamado «BrunOS AssistiveTouch» con la acción "
                + "«Establecer AssistiveTouch» puesta en activar."
        case .automationOnOpen:
            "En Automatización, añade una de App: BrunOS, «Se abre», con "
                + "«Establecer AssistiveTouch: activado» y «Ejecutar inmediatamente»."
        case .automationOnClose:
            "Repite la automatización con «Se cierra» y «Establecer "
                + "AssistiveTouch: desactivado»."
        }
    }

    var defaultsKey: String { "assistiveTouch.step.\(rawValue)" }

    var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
