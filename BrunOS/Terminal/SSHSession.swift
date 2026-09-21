// Ni Citadel ni NIO están migrados a la concurrencia estricta de Swift 6: sus
// tipos de sesión y de canal no son `Sendable`. `@preconcurrency` degrada eso a
// aviso. Es legítimo porque todo lo que cruza de hilo aquí pasa por
// `MainActor.run`, y el cliente lo maneja el event loop de NIO en el suyo.
@preconcurrency import Citadel
import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

/// Una sesión interactiva contra una máquina.
///
/// Es la capa que separa a SwiftTerm de Citadel: el terminal habla en bytes y
/// en filas por columnas, y aquí se traduce a lo que entiende SSH.
///
/// **La clave del servidor se comprueba** contra las conocidas, al estilo de
/// `known_hosts`: la primera vez se guarda y a partir de ahí tiene que
/// coincidir. Si cambia, no se conecta. Ver `KnownHosts.swift`.
@MainActor
final class SSHSession {

    enum State: Equatable {
        case idle
        case connecting
        case connected
        /// Se cayó o no se pudo conectar. El texto es para enseñárselo a Bruno,
        /// no para que lo lea un programa.
        case failed(String)

        var isConnected: Bool { self == .connected }
    }

    let host: SSHHost
    private(set) var state: State = .idle

    /// Lo que llega de la máquina, ya en bytes, para dárselo al terminal.
    var onOutput: (@MainActor (ArraySlice<UInt8>) -> Void)?
    var onStateChange: (@MainActor (State) -> Void)?

    /// Lo que se le manda a la sesión mientras vive.
    ///
    /// Existe porque `TTYStdinWriter` **no es `Sendable`** y no puede salir de
    /// la closure de `withPTY`. En vez de sacarlo, se le mandan órdenes por un
    /// flujo, que sí lo es. El writer se queda dentro, donde nació.
    private enum Input: Sendable {
        case data([UInt8])
        case resize(cols: Int, rows: Int)
    }

    private var inputContinuation: AsyncStream<Input>.Continuation?
    private var sessionTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    /// Último tamaño conocido del panel, para no pedir un PTY de 80×24 cuando
    /// el panel ya sabe que mide otra cosa.
    private var size = (cols: 80, rows: 24)

    init(host: SSHHost) {
        self.host = host
    }

    // MARK: - Conexión

    func connect() {
        guard state != .connecting, !state.isConnected else { return }
        setState(.connecting)

        sessionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run()
            } catch is CancellationError {
                // Cierre pedido por quien usa la app: no es un fallo.
            } catch {
                self.setState(.failed(Self.describe(error)))
            }
            self.teardown()
        }
    }

    func disconnect() {
        sessionTask?.cancel()
        sessionTask = nil
        teardown()
        setState(.idle)
    }

    private func run() async throws {
        let password = host.authentication == .password
            ? SSHKeychain.password(for: host) ?? ""
            : ""

        let knownHosts = AppServices.shared.knownHosts
        let known = knownHosts.entry(host: host.host, port: host.port)?.fingerprint

        let (input, inputContinuation) = AsyncStream<Input>.makeStream()
        self.inputContinuation = inputContinuation

        let (output, outputContinuation) = AsyncStream<[UInt8]>.makeStream()

        // La salida se consume aquí, en el MainActor, para poder dársela al
        // terminal sin cruzar nada que no sea un array de bytes.
        let pump = Task { [weak self] in
            for await bytes in output {
                guard let self else { return }
                self.onOutput?(ArraySlice(bytes))
            }
        }
        defer { pump.cancel() }

        let host = self.host
        let size = self.size
        setState(.connected)
        startKeepAlive()

        try await Self.runSession(
            host: host,
            password: password,
            knownFingerprint: known,
            size: size,
            input: input,
            output: outputContinuation,
            onHostKey: { matched, fingerprint in
                Task { @MainActor in
                    let store = AppServices.shared.knownHosts
                    if matched {
                        store.trust(fingerprint: fingerprint, host: host.host, port: host.port)
                    } else {
                        store.noteChange(fingerprint: fingerprint, host: host.host, port: host.port)
                    }
                }
            }
        )
    }

    /// Todo el trabajo de red, **fuera del actor principal**.
    ///
    /// Es `nonisolated` a propósito: lo que Citadel entrega dentro de `withPTY`
    /// no es `Sendable`, así que no puede cruzar a `MainActor`. Se queda aquí y
    /// sólo salen arrays de bytes, que sí pueden viajar.
    private nonisolated static func runSession(
        host: SSHHost,
        password: String,
        knownFingerprint: String?,
        size: (cols: Int, rows: Int),
        input: AsyncStream<Input>,
        output: AsyncStream<[UInt8]>.Continuation,
        onHostKey: @escaping @Sendable (Bool, String) -> Void
    ) async throws {
        let authentication: SSHAuthenticationMethod = switch host.authentication {
        case .tailscale: .tailscale(username: host.username)
        case .password: .passwordBased(username: host.username, password: password)
        }

        let client = try await SSHClient.connect(
            host: host.host,
            port: host.port,
            authenticationMethod: authentication,
            hostKeyValidator: .custom(KnownHostsValidator(
                host: host.host,
                port: host.port,
                known: knownFingerprint,
                onResult: onHostKey
            )),
            reconnect: .never
        )
        defer { Task { try? await client.close() } }

        try await client.withPTY(
            SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: size.cols,
                terminalRowHeight: size.rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: .init([:])
            )
        ) { inbound, outbound in
            if !host.initialCommand.isEmpty {
                try await outbound.write(ByteBuffer(string: host.initialCommand + "\n"))
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                // Lo que llega de la máquina.
                group.addTask {
                    for try await chunk in inbound {
                        // stdout y stderr van los dos al terminal: es lo que
                        // hace cualquier consola, y separarlos aquí sólo
                        // perdería el orden en que ocurrieron.
                        let buffer = switch chunk {
                        case .stdout(let value): value
                        case .stderr(let value): value
                        }
                        output.yield(Array(buffer.readableBytesView))
                    }
                    output.finish()
                }

                // Lo que se teclea y los cambios de tamaño.
                group.addTask {
                    for await command in input {
                        switch command {
                        case .data(let bytes):
                            try await outbound.write(ByteBuffer(bytes: bytes))
                        case .resize(let cols, let rows):
                            try await outbound.changeSize(
                                cols: cols, rows: rows,
                                pixelWidth: 0, pixelHeight: 0
                            )
                        }
                    }
                }

                // En cuanto una de las dos acabe, se acabó la sesión.
                try await group.next()
                group.cancelAll()
            }
        }
    }

    private func teardown() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
    }

    // MARK: - Entrada y tamaño

    /// Manda al servidor lo que se teclea en el terminal.
    func send(_ data: ArraySlice<UInt8>) {
        inputContinuation?.yield(.data(Array(data)))
    }

    func send(_ text: String) {
        send(ArraySlice(Array(text.utf8)))
    }

    /// Avisa al servidor del nuevo tamaño al redimensionar el panel.
    ///
    /// Es lo que hace que vim y tmux se recoloquen en vez de quedarse pintando
    /// sobre una cuadrícula que ya no existe.
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, (cols, rows) != size else { return }
        size = (cols, rows)
        inputContinuation?.yield(.resize(cols: cols, rows: rows))
    }

    // MARK: - Mantener viva la sesión

    /// Un carácter nulo cada 30 s.
    ///
    /// Sirve para que los cortafuegos y los NAT por el camino no den la
    /// conexión por muerta y la tiren. Se manda un byte que ningún shell
    /// interpreta como nada.
    private func startKeepAlive() {
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.state.isConnected else { return }
                self.send(ArraySlice([0x00]))
            }
        }
    }

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }

    private static func describe(_ error: any Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription {
            return described
        }
        return String(describing: error)
    }
}
