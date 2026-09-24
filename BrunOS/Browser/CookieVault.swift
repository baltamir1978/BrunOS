import Foundation
import WebKit

/// Una copia propia de las cookies persistentes del navegador.
///
/// Las guarda WebKit en disco (`WKWebsiteDataStore.default()`), pero lo hace
/// **cuando le parece**, desde su proceso de red. Si iOS cierra la app antes
/// —por memoria, al quitarla del multitarea o al instalar una build nueva—
/// lo último se pierde, y Bruno veía el aviso de cookies de Google cada vez
/// que la abría: justo lo que se acepta al final, sin navegar después.
///
/// Así que se apuntan aparte en cuanto cambian, y al arrancar se devuelven
/// las que falten. Sólo las que tienen fecha de caducidad: las de sesión se
/// tienen que perder al cerrar, como en Safari.
@MainActor
final class CookieVault: NSObject, WKHTTPCookieStoreObserver {

    static let shared = CookieVault()

    private var store: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }
    private var saveTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "cookies.plist")
    }

    /// Repone las cookies guardadas y empieza a vigilar los cambios. Se puede
    /// llamar varias veces: todas esperan a la misma restauración.
    func restore() async {
        if restoreTask == nil {
            restoreTask = Task { await self.performRestore() }
        }
        await restoreTask?.value
    }

    private func performRestore() async {
        defer { store.add(self) }
        guard let data = try? Data(contentsOf: Self.fileURL),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [[String: Any]]
        else { return }

        let existing = Set(await store.allCookies().map(Self.identity))
        let now = Date()
        for properties in list {
            let keyed = Dictionary(uniqueKeysWithValues: properties.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            guard let cookie = HTTPCookie(properties: keyed),
                  let expires = cookie.expiresDate, expires > now,
                  !existing.contains(Self.identity(cookie))
            else { continue }
            await store.setCookie(cookie)
        }
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        MainActor.assumeIsolated { scheduleSave() }
    }

    /// Guarda ya, sin esperar. Para cuando la app se va a segundo plano.
    func saveNow() {
        saveTask?.cancel()
        saveTask = Task { await self.save() }
    }

    /// Una página puede cambiar veinte cookies seguidas al cargar: se guarda
    /// una vez, un momento después de la última.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self.save()
        }
    }

    private func save() async {
        let now = Date()
        let list: [[String: Any]] = await store.allCookies().compactMap { cookie in
            guard let expires = cookie.expiresDate, expires > now,
                  let properties = cookie.properties
            else { return nil }
            // Sólo lo que cabe en un plist: el resto (una URL de origen) se
            // pasa a texto o se deja fuera.
            var plist: [String: Any] = [:]
            for (key, value) in properties {
                switch value {
                case let url as URL: plist[key.rawValue] = url.absoluteString
                case is String, is Date, is NSNumber, is [NSNumber], is [String]: plist[key.rawValue] = value
                default: continue
                }
            }
            return plist
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        else { return }
        var url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // Son sesiones iniciadas: no tienen por qué ir en la copia de iCloud.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func identity(_ cookie: HTTPCookie) -> String {
        "\(cookie.domain)|\(cookie.path)|\(cookie.name)"
    }
}
