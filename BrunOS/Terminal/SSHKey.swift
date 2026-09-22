@preconcurrency import Citadel
import CryptoKit
import Foundation
import Security

/// La clave SSH del iPhone: una ed25519, como el `~/.ssh/id_ed25519` de un Mac.
///
/// Se genera en el propio teléfono o se importa una propia desde el
/// portapapeles, en formato OpenSSH (el de `ssh-keygen`), también cifrada con
/// frase de paso. Hay **una** para todas las máquinas con el método «Clave»:
/// es lo que hace `ssh` por defecto, y basta con pegar la pública en el
/// `authorized_keys` de cada una.
///
/// Va al Keychain con `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, igual
/// que las contraseñas: no se sincroniza con iCloud y no se lee con el
/// teléfono bloqueado. **La privada no sale nunca de ahí**: la app sólo
/// enseña y copia la pública.
enum SSHKeyStore {

    private static let service = "com.baltamir.brunos.sshkey"
    private static let account = "ed25519"

    static let comment = "brunos@iphone"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func privateKey() -> Curve25519.Signing.PrivateKey? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    static var hasKey: Bool { privateKey() != nil }

    /// Una clave nueva. Sustituye a la que hubiera: las máquinas que tuvieran
    /// la pública anterior dejan de aceptar la conexión.
    @discardableResult
    static func generate() -> Curve25519.Signing.PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        store(key)
        return key
    }

    /// Importa una clave privada en formato OpenSSH (`-----BEGIN OPENSSH
    /// PRIVATE KEY-----`). Sólo ed25519: es la que admite este método.
    static func importOpenSSH(_ text: String, passphrase: String?) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("OPENSSH PRIVATE KEY") else {
            throw FileError.failed("Eso no es una clave privada de OpenSSH. Tiene que empezar por "
                                   + "«-----BEGIN OPENSSH PRIVATE KEY-----».")
        }
        do {
            let key = try Curve25519.Signing.PrivateKey(
                sshEd25519: trimmed,
                decryptionKey: passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            )
            store(key)
        } catch {
            throw FileError.failed("No se pudo leer la clave. ¿Es ed25519? Si está cifrada, "
                                   + "hace falta su frase de paso.")
        }
    }

    static func remove() {
        SecItemDelete(query as CFDictionary)
        notify()
    }

    private static func store(_ key: Curve25519.Signing.PrivateKey) {
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
        notify()
    }

    private static func notify() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .brunosSettingsChanged, object: nil)
        }
    }

    // MARK: - Clave pública

    /// La línea que va en `authorized_keys`: `ssh-ed25519 AAAA… brunos@iphone`.
    static var publicKeyLine: String? {
        guard let blob = publicKeyBlob else { return nil }
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    /// Huella SHA-256 en el formato de OpenSSH, para cotejarla con
    /// `ssh-keygen -lf`.
    static var fingerprint: String? {
        guard let blob = publicKeyBlob else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// El formato de clave pública de SSH: el tipo y los 32 bytes, cada uno
    /// precedido de su longitud en cuatro bytes.
    private static var publicKeyBlob: Data? {
        guard let key = privateKey() else { return nil }
        var blob = Data()
        for part in [Data("ssh-ed25519".utf8), key.publicKey.rawRepresentation] {
            var length = UInt32(part.count).bigEndian
            blob.append(Data(bytes: &length, count: 4))
            blob.append(part)
        }
        return blob
    }
}
