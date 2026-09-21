import Citadel
import NIOCore
// NIOSSH todavía no está migrado a la concurrencia estricta de Swift 6 y sus
// tipos no son `Sendable`. `@preconcurrency` degrada eso a aviso, que es para
// lo que existe: aquí el delegado lo usa el event loop de NIO, en su hilo, y
// no lo comparte con nadie.
@preconcurrency import NIOSSH

/// Autenticación por el método SSH `none`, que es el que usa Tailscale SSH.
///
/// **Citadel no lo expone.** Sus constructores llegan hasta `passwordBased` y
/// las claves, pero el caso `none` de `NIOSSHUserAuthenticationOffer.Offer`
/// existe y no hay forma pública de pedirlo. Lo que sí es público es
/// `SSHAuthenticationMethod.custom(_:)`, que acepta un delegado propio, así que
/// basta con escribir este.
///
/// **Qué significa `none` aquí.** No es "entrar sin autenticarse": Tailscale
/// autentica antes, por la identidad del tailnet y las ACL del nodo, y el
/// servidor SSH acepta el método `none` porque la comprobación ya está hecha a
/// nivel de red. Fuera de un tailnet, un servidor que acepte `none` es otra
/// cosa muy distinta y muy mala idea.
///
/// El delegado ofrece `none` **una sola vez**. Si el servidor lo rechaza, se
/// falla el `promise` en lugar de insistir: reintentar en bucle sólo conseguiría
/// que el servidor cortara la conexión, y el mensaje de error que llega así es
/// mucho menos claro.
final class TailscaleAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {

    private let username: String
    private var hasOffered = false

    init(username: String) {
        self.username = username
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !hasOffered else {
            // Ya se ofreció y no coló: el servidor no acepta `none` para este
            // usuario. Lo habitual es que Tailscale SSH no esté habilitado en
            // ese nodo, o que las ACL no permitan la conexión.
            nextChallengePromise.fail(TailscaleAuthenticationError.noneRejected)
            return
        }
        hasOffered = true

        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .none
            )
        )
    }
}

/// **`keyboard-interactive` no existe en esta pila y no se puede añadir.**
///
/// Comprobado en la librería: `NIOSSHAvailableUserAuthenticationMethods` sólo
/// contempla `publicKey`, `password` y `hostBased`, y la cadena
/// "keyboard-interactive" no aparece en ningún fichero de NIOSSH. No es que
/// falte por implementar en BrunOS: **la librería no habla ese método**.
///
/// Importa porque hay servidores OpenSSH con `KbdInteractiveAuthentication yes`
/// y `PasswordAuthentication no`, y contra ésos la contraseña no entra. La
/// salida sería una clave pública, que Citadel sí admite, o parchear NIOSSH.
enum TailscaleAuthenticationError: Error, LocalizedError {
    case noneRejected

    var errorDescription: String? {
        "El servidor rechazó la autenticación de Tailscale. Comprueba que "
            + "Tailscale SSH esté activado en esa máquina y que las ACL del "
            + "tailnet permitan la conexión."
    }
}

extension SSHAuthenticationMethod {

    /// Autenticación de Tailscale SSH, con el método `none`.
    static func tailscale(username: String) -> SSHAuthenticationMethod {
        .custom(TailscaleAuthenticationDelegate(username: username))
    }
}
