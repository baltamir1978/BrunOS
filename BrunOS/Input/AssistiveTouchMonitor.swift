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

    /// Enciende AssistiveTouch por la mejor vía disponible.
    ///
    /// Primero se intenta la **API oficial**, `UIGuidedAccessConfigureAccessibilityFeatures`.
    /// Es pública desde iOS 12.2 y sabe encender AssistiveTouch de verdad, pero
    /// la cabecera es tajante sobre cuándo: sólo funciona en apps **bloqueadas
    /// en modo de app única mediante un perfil de gestión de dispositivos**,
    /// pensada para montajes de tipo quiosco. En un iPhone normal falla, y por
    /// eso queda el atajo como plan B.
    ///
    /// Se intenta igual porque no cuesta nada y, si algún día el iPhone está
    /// supervisado, deja de hacer falta el atajo y todo el asistente sobra.
    func enable() {
        lastAttempt = nil

        UIAccessibility.configureForGuidedAccess(
            features: .assistiveTouch,
            enabled: true
        ) { [weak self] succeeded, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if succeeded {
                    self.refresh()
                    self.lastAttempt = self.isRunning ? .worked : .ranButNothingChanged
                    self.usedOfficialAPI = true
                } else {
                    // Lo esperable en un iPhone sin supervisar.
                    self.runShortcut()
                }
            }
        }
    }

    /// Si la vía oficial llegó a funcionar. Si es que sí, el asistente sobra.
    private(set) var usedOfficialAPI = false

    /// Lanza el atajo y deja anotado el resultado.
    func runShortcut() {
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
/// una automatización de Atajos existe. Lo único observable es si AssistiveTouch
/// está activo, y con eso se rotula "Configurado" cuando lo observado coincide
/// con lo esperado.
///
/// Las instrucciones viven aquí y no en la vista porque **la app tiene que
/// explicarse sola**. Que haya que salir a buscar a alguien que te cuente por
/// qué un botón no hace nada es un fallo de la app, no del que la usa.
enum AssistiveTouchStep: String, CaseIterable, Identifiable {
    case createShortcut
    case automationOnOpen
    case automationOnClose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .createShortcut: "Crear el atajo"
        case .automationOnOpen: "Encenderlo al abrir BrunOS"
        case .automationOnClose: "Apagarlo al salir"
        }
    }

    /// Para qué sirve este paso, en una línea.
    var purpose: String {
        switch self {
        case .createShortcut:
            "Es lo que hace que el botón «Activar» de BrunOS tenga algo que ejecutar."
        case .automationOnOpen:
            "Con esto no tendrás que volver a pulsar nada: el ratón funcionará "
                + "en cuanto abras BrunOS."
        case .automationOnClose:
            "Deja el iPhone como estaba. Con AssistiveTouch encendido queda un "
                + "círculo gris flotando en la pantalla, y molesta en el resto de apps."
        }
    }

    /// Los pasos concretos, tal cual hay que darlos en la app Atajos.
    var instructions: [String] {
        switch self {
        case .createShortcut:
            [
                "Abre la app Atajos y ve a la pestaña «Atajos».",
                "Toca el + de arriba a la derecha.",
                "Busca la acción «Establecer AssistiveTouch» y añádela.",
                "Comprueba que ponga «activar», no «desactivar» ni «alternar».",
                "Ponle de nombre exactamente el que aparece abajo, sin espacios de más.",
            ]
        case .automationOnOpen:
            [
                "En Atajos, ve a la pestaña «Automatización».",
                "Toca el + y elige «App».",
                "En «App» elige BrunOS, y marca «Se abre».",
                "Marca también «Ejecutar inmediatamente», o iOS pedirá confirmación cada vez.",
                "Añade la acción «Establecer AssistiveTouch» puesta en «activado».",
            ]
        case .automationOnClose:
            [
                "Repite lo mismo: Automatización, +, «App», BrunOS.",
                "Esta vez marca «Se cierra» en lugar de «Se abre».",
                "Marca «Ejecutar inmediatamente».",
                "Añade «Establecer AssistiveTouch» puesta en «desactivado».",
            ]
        }
    }

    var defaultsKey: String { "assistiveTouch.step.\(rawValue)" }

    var isDone: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
