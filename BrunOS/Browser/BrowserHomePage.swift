import Foundation

/// Lo que abre una pestaña nueva: la página de BrunOS (favoritos y la ayuda de
/// la app) o una dirección que elija Bruno. Se cambia en Ajustes del
/// navegador › General.
@MainActor
enum BrowserHomePage {

    private static let key = "browser.homePage"

    /// `nil` es la página de BrunOS.
    static var address: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: key) ?? ""
            return stored.isEmpty ? nil : stored
        }
        set { UserDefaults.standard.set(newValue ?? "", forKey: key) }
    }
}
