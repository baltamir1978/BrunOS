import Observation
import UIKit

/// Encapsula todo lo que iOS 27 cambió en la pantalla externa.
///
/// Hasta iOS 26 bastaba con declarar una escena `windowExternalDisplayNonInteractive`
/// en el manifiesto y el sistema la ofrecía sola al conectar un monitor. **En iOS 27
/// eso ya no ocurre**: el contenido externo se declara desde el view controller raíz
/// del iPhone con `registerSceneAccessory(_:)`, pasando un `UISceneAccessory`
/// creado con `externalNonInteractive(sceneConfiguration:)`.
///
/// Dos detalles que no están en las notas de versión y cuestan una tarde:
///
/// 1. El accesorio exige un `UISceneConfiguration` **sin rol de sesión**. Ese
///    inicializador, `UISceneConfiguration(name:)`, es nuevo en iOS 27; el rol lo
///    decide el propio accesorio. Pasar un `.windowApplication` no compila el caso.
/// 2. `registerSceneAccessory` devuelve un `UISceneAccessoryRegistration` que **hay
///    que conservar**. Si se descarta, se pierde el control de `isEnabled` y no se
///    puede desregistrar. Su propiedad `isAvailable` sólo es observable dentro de
///    `updateProperties()` y `layoutSubviews()`.
///
/// **Es `@Observable` por la interfaz del iPhone**, que decide entre la pantalla
/// normal y el modo mando mirando `currentProfile`. Sin observación, SwiftUI no
/// se enteraba del cambio: al conectar funcionaba de rebote, porque cambiaba a la
/// vez otra cosa que sí era observable, pero al desconectar el iPhone se quedaba
/// en modo mando, en negro.
@MainActor
@Observable
final class ExternalDisplayManager {

    /// Se avisa cuando el sistema conecta o desconecta la pantalla externa, para
    /// que el escritorio recalcule el mosaico y recoloque el cursor.
    static let didChangeNotification = Notification.Name("BrunOSExternalDisplayDidChange")

    @ObservationIgnored private(set) var registration: UISceneAccessoryRegistration?
    @ObservationIgnored private(set) weak var externalWindow: UIWindow?
    /// Se conserva para poder enseñar el diagnóstico en los ajustes del iPhone.
    @ObservationIgnored private(set) weak var currentScreen: UIScreen?
    @ObservationIgnored private let store = DisplayProfileStore()

    /// Perfil de la pantalla conectada ahora mismo, si la hay.
    private(set) var currentProfile: DisplayProfile?

    /// Registra el contenido externo desde el view controller raíz del iPhone.
    ///
    /// Llamarlo una sola vez, en `viewDidLoad` del raíz. El sistema presenta el
    /// contenido cuando hay monitor; mientras no lo haya, no pasa nada y la app
    /// tiene que seguir siendo plenamente utilizable en el teléfono.
    func register(from viewController: UIViewController) {
        guard registration == nil else { return }

        let configuration = UISceneConfiguration(name: "BrunOSExternal")
        configuration.delegateClass = ExternalSceneDelegate.self

        let accessory = UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration)
        registration = viewController.registerSceneAccessory(accessory)

        Log.display.info("Accesorio de escena externa registrado")
    }

    // MARK: - Ciclo de vida de la pantalla

    /// Resolución real de la pantalla, en píxeles.
    ///
    /// **No se usa `nativeBounds`**, aunque el nombre lo sugiera. Esa propiedad
    /// describe el panel del propio dispositivo y en una pantalla externa no
    /// tiene por qué corresponderse con el modo de vídeo que se está emitiendo;
    /// era el motivo de que BrunOS rotulase una resolución que no era la del
    /// monitor.
    ///
    /// La fuente buena es `currentMode.size`, que **son los píxeles del modo de
    /// vídeo activo**. Si no hubiera modo, se deduce de los puntos por su
    /// factor de escala, que es la definición de `scale`.
    static func pixelSize(of screen: UIScreen) -> CGSize {
        if let mode = screen.currentMode, mode.size.width > 0 {
            return mode.size
        }
        return CGSize(
            width: screen.bounds.width * screen.scale,
            height: screen.bounds.height * screen.scale
        )
    }

    /// Lo que el sistema dice de la pantalla, en crudo. Se enseña en los
    /// ajustes del iPhone porque el monitor lo ve Bruno y no quien programa.
    static func diagnostics(for screen: UIScreen) -> [(String, String)] {
        [
            ("bounds", "\(Int(screen.bounds.width))×\(Int(screen.bounds.height)) pt"),
            ("scale", String(format: "%.2f", screen.scale)),
            ("nativeBounds", "\(Int(screen.nativeBounds.width))×\(Int(screen.nativeBounds.height)) px"),
            ("nativeScale", String(format: "%.2f", screen.nativeScale)),
            ("currentMode", screen.currentMode.map {
                "\(Int($0.size.width))×\(Int($0.size.height)) px"
            } ?? "ninguno"),
            ("modos", "\(screen.availableModes.count)"),
            ("en uso", "\(Int(pixelSize(of: screen).width))×\(Int(pixelSize(of: screen).height)) px"),
        ]
    }

    /// La llama `ExternalSceneDelegate` cuando el sistema conecta la escena.
    func attach(window: UIWindow, screen: UIScreen) {
        externalWindow = window
        currentScreen = screen

        // La compensación de overscan de UIKit recorta o escala según la tele y
        // estropea la nitidez. BrunOS aplica su propio margen en espacio lógico.
        screen.overscanCompensation = .none

        let profile = store.profile(forNativePixels: Self.pixelSize(of: screen))
        currentProfile = profile
        store.save(profile)

        logCharacteristics(of: screen, profile: profile)
        AppServices.shared.assistiveTouch.hasExternalDisplay = true
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// La llama `ExternalSceneDelegate` al desconectar.
    ///
    /// No se tira el estado de los paneles: al volver a enchufar el monitor todo
    /// tiene que reaparecer como estaba.
    func detach() {
        // Llega por dos vías —`sceneDidDisconnect` y la disponibilidad del
        // accesorio— y la segunda no tiene que hacer nada.
        guard externalWindow != nil || currentProfile != nil else { return }
        EventLog.note("Monitor: se da por desconectado (se conservan los paneles)")
        AppServices.shared.pointer.detach()
        externalWindow = nil
        currentScreen = nil
        currentProfile = nil
        AppServices.shared.assistiveTouch.hasExternalDisplay = false
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Cambia la escala guardada para la pantalla actual y avisa al escritorio.
    func setScale(_ scale: DisplayProfile.Scale) {
        guard var profile = currentProfile else { return }
        profile.scale = scale
        currentProfile = profile
        store.save(profile)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Cambia el margen de overscan guardado para la pantalla actual.
    func setOverscan(_ overscan: DisplayProfile.Overscan) {
        guard var profile = currentProfile else { return }
        profile.overscan = overscan
        currentProfile = profile
        store.save(profile)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - Diagnóstico

    /// Deja en el log lo que hace falta para entender qué modo eligió iOS.
    ///
    /// BrunOS **no fuerza el modo de vídeo**: se queda con el que elija el sistema,
    /// que normalmente es el nativo del monitor. Este registro sirve para
    /// comprobarlo cuando algo se ve raro en una tele concreta.
    private func logCharacteristics(of screen: UIScreen, profile: DisplayProfile) {
        let native = Self.pixelSize(of: screen)
        Log.display.info("""
            Pantalla externa conectada
              bounds: \(Int(screen.bounds.width))×\(Int(screen.bounds.height)) pt, scale \(screen.scale, format: .fixed(precision: 2))
              nativeBounds: \(Int(screen.nativeBounds.width))×\(Int(screen.nativeBounds.height)) px
              píxeles en uso: \(Int(native.width))×\(Int(native.height))
              nativeScale: \(screen.nativeScale, format: .fixed(precision: 2))
              currentMode: \(String(describing: screen.currentMode?.size))
              modos disponibles: \(screen.availableModes.count)
              perfil: escala \(profile.scale.label), overscan \(profile.overscan.label)
              lógico: \(profile.summary)
            """)

        for mode in screen.availableModes {
            Log.display.debug("  modo \(Int(mode.size.width))×\(Int(mode.size.height))")
        }
    }
}
