import Citadel
import CryptoKit
import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// Las claves de host que BrunOS ya ha visto, al estilo de `known_hosts`.
///
/// **Para qué sirve esto.** La criptografía de SSH garantiza que nadie escucha
/// por el camino, pero no dice con *quién* estás hablando. Eso lo dice la clave
/// del servidor. Sin comprobarla, cualquiera que se meta en medio puede
/// presentarse como tu máquina, y tú le entregas la contraseña sin enterarte.
///
/// Se sigue el modelo de OpenSSH, **confianza en el primer uso**: la primera vez
/// que se ve una máquina se guarda su clave y se acepta; a partir de ahí tiene
/// que coincidir. Si cambia, se corta la conexión y se avisa.
///
/// No es infalible —si el primer encuentro ya estuviera interceptado, se
/// guardaría la clave del atacante— pero es lo que hace `ssh` de toda la vida y
/// detecta todo lo demás.
@MainActor
@Observable
final class KnownHostsStore {

    /// Una clave vista, identificada por host y puerto.
    struct Entry: Codable, Identifiable, Equatable, Sendable {
        /// `host:puerto`, como en `known_hosts`.
        var id: String
        /// Huella SHA-256 en base64, el formato que enseña OpenSSH.
        var fingerprint: String
        var firstSeen: Date

        var displayFingerprint: String { "SHA256:\(fingerprint)" }
    }

    private(set) var entries: [Entry] = []

    /// Claves que no coincidieron y están esperando una decisión.
    private(set) var pendingChanges: [String: String] = [:]

    private let url: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("known_hosts.json")
    }()

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = stored
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func key(host: String, port: Int) -> String {
        port == 22 ? host : "\(host):\(port)"
    }

    func entry(host: String, port: Int) -> Entry? {
        entries.first { $0.id == Self.key(host: host, port: port) }
    }

    /// Guarda una clave para una máquina, sustituyendo la anterior si la había.
    func trust(fingerprint: String, host: String, port: Int) {
        let id = Self.key(host: host, port: port)
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, fingerprint: fingerprint, firstSeen: Date()))
        pendingChanges[id] = nil
        save()
    }

    func forget(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        pendingChanges[entry.id] = nil
        save()
    }

    /// Apunta que una máquina presentó una clave distinta de la guardada.
    func noteChange(fingerprint: String, host: String, port: Int) {
        pendingChanges[Self.key(host: host, port: port)] = fingerprint
    }
}

/// Comprueba la clave del servidor contra las conocidas.
///
/// Es `Sendable` y sin estado mutable a propósito: NIO lo llama desde su event
/// loop, no desde el actor principal, así que recibe las claves ya resueltas y
/// sólo avisa por un callback.
struct KnownHostsValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {

    let host: String
    let port: Int
    /// Huella guardada para esta máquina, o `nil` si no se ha visto nunca.
    let known: String?
    /// Se llama con la huella vista. El primer parámetro dice si coincidía.
    let onResult: @Sendable (_ matched: Bool, _ fingerprint: String) -> Void

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = Self.fingerprint(of: hostKey)

        guard let known else {
            // Primera vez que se ve esta máquina: se acepta y se guarda.
            onResult(true, fingerprint)
            validationCompletePromise.succeed(())
            return
        }

        if known == fingerprint {
            onResult(true, fingerprint)
            validationCompletePromise.succeed(())
        } else {
            // **No se conecta.** Puede ser que reinstalaran el servidor, o que
            // alguien esté en medio. Desde aquí no hay forma de distinguirlo,
            // así que decide Bruno.
            onResult(false, fingerprint)
            validationCompletePromise.fail(HostKeyChanged(host: host, fingerprint: fingerprint))
        }
    }

    /// Huella SHA-256 en base64, sin el `=` final: el formato que enseña OpenSSH
    /// y con el que se puede cotejar a ojo contra `ssh-keyscan`.
    static func fingerprint(of key: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 256)
        _ = key.write(to: &buffer)
        let bytes = Data(buffer.readableBytesView)
        let digest = SHA256.hash(data: bytes)
        return Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// La máquina presentó una clave distinta de la que teníamos guardada.
struct HostKeyChanged: Error, LocalizedError {
    let host: String
    let fingerprint: String

    var errorDescription: String? {
        """
        LA CLAVE DE \(host) HA CAMBIADO.

        Puede que hayan reinstalado el servidor, o que alguien se haya puesto en \
        medio de la conexión. BrunOS no puede distinguir una cosa de la otra, así \
        que no se conecta.

        La clave nueva es SHA256:\(fingerprint). Si el cambio lo esperabas, \
        acéptala en Ajustes › SSH › Claves conocidas.
        """
    }
}
