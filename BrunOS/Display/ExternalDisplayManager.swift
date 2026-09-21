import OSLog
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
@MainActor
final class ExternalDisplayManager {

    static let logger = Logger(subsystem: "com.bruno.brunos", category: "display")

    /// Se avisa cuando el sistema conecta o desconecta la pantalla externa, para
    /// que el escritorio recalcule el mosaico y recoloque el cursor.
    static let didChangeNotification = Notification.Name("BrunOSExternalDisplayDidChange")

    private(set) var registration: UISceneAccessoryRegistration?
    private(set) weak var externalWindow: UIWindow?
    private let store = DisplayProfileStore()

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

        Self.logger.info("Accesorio de escena externa registrado")
    }

    // MARK: - Ciclo de vida de la pantalla

    /// La llama `ExternalSceneDelegate` cuando el sistema conecta la escena.
    func attach(window: UIWindow, screen: UIScreen) {
        externalWindow = window

        // La compensación de overscan de UIKit recorta o escala según la tele y
        // estropea la nitidez. BrunOS aplica su propio margen en espacio lógico.
        screen.overscanCompensation = .none

        let profile = store.profile(forNativePixels: screen.nativeBounds.size)
        currentProfile = profile
        store.save(profile)

        logCharacteristics(of: screen, profile: profile)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// La llama `ExternalSceneDelegate` al desconectar.
    ///
    /// No se tira el estado de los paneles: al volver a enchufar el monitor todo
    /// tiene que reaparecer como estaba.
    func detach() {
        Self.logger.info("Pantalla externa desconectada; se conserva el estado de los paneles")
        externalWindow = nil
        currentProfile = nil
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
        let native = screen.nativeBounds.size
        Self.logger.info("""
            Pantalla externa conectada
              nativeBounds: \(Int(native.width))×\(Int(native.height)) px
              nativeScale: \(screen.nativeScale, format: .fixed(precision: 2))
              currentMode: \(String(describing: screen.currentMode?.size))
              modos disponibles: \(screen.availableModes.count)
              perfil: escala \(profile.scale.label), overscan \(profile.overscan.label)
              lógico: \(profile.summary)
            """)

        for mode in screen.availableModes {
            Self.logger.debug("  modo \(Int(mode.size.width))×\(Int(mode.size.height))")
        }
    }
}
