import UIKit

/// iOS 27 obliga al ciclo de vida basado en escenas: sin el manifiesto del
/// `Info.plist` la app ni siquiera arranca. El delegado de aplicación queda para
/// lo poco que sigue siendo global.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }

    /// Sólo se resuelve aquí la escena del iPhone.
    ///
    /// La escena externa **no** se declara ni aquí ni en el manifiesto: en iOS 27
    /// la aporta el accesorio de escena que registra el view controller raíz.
    /// Ver `ExternalDisplayManager`.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Phone",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = PhoneSceneDelegate.self
        return configuration
    }
}
