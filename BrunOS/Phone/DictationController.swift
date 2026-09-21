import AVFoundation
import Observation
import Speech
import SwiftUI

/// Dictado en el dispositivo, hacia el panel que tenga el foco.
///
/// Usa `SpeechAnalyzer` con `SpeechTranscriber`, la vía moderna: **todo ocurre
/// en el iPhone**, sin pasar por ningún servidor, cosa que importa cuando lo
/// que se dicta son órdenes de consola.
///
/// El modelo de cada idioma **se descarga la primera vez**, así que la primera
/// pulsación puede tardar. Por eso hay un estado `preparando` de cara al usuario
/// en vez de quedarse mudo.
@MainActor
@Observable
final class DictationController {

    enum State: Equatable {
        case idle
        case preparing
        case listening
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Lo último reconocido, para poder enseñarlo mientras se habla.
    private(set) var transcript = ""

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    var isActive: Bool { state == .listening || state == .preparing }

    func toggle() {
        if isActive {
            stop()
        } else {
            start()
        }
    }

    // MARK: - Arranque

    private func start() {
        state = .preparing
        transcript = ""

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.beginSession()
            } catch {
                self.state = .failed(Self.describe(error))
                self.teardown()
            }
        }
    }

    private func beginSession() async throws {
        guard await requestPermission() else {
            state = .failed("Sin permiso para el micrófono")
            return
        }

        // El idioma sale del que tenga puesto el sistema: dictar en español en
        // un teléfono en español es lo que uno espera sin configurar nada.
        let locale = Locale.current
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        // El modelo puede no estar todavía. Se pide y se espera, que es la
        // razón de que exista el estado "preparando".
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = continuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        try await startAudio(feeding: continuation)
        try await analyzer.start(inputSequence: stream)

        state = .listening
        listenForResults(from: transcriber)
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startAudio(feeding continuation: AsyncStream<AnalyzerInput>.Continuation) async throws {
        let session = AVAudioSession.sharedInstance()
        // `.mixWithOthers` para no cortar lo que esté sonando: BrunOS puede
        // tener un vídeo en el navegador mientras se dicta en el terminal.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // El búfer tiene que caer en [100, 400] ms según la cabecera: 8192
        // muestras son unos 170 ms a 48 kHz.
        input.installBrunOSTap(bufferSize: 8_192, format: format) { buffer in
            continuation.yield(AnalyzerInput(buffer: buffer))
        }

        engine.prepare()
        try engine.start()
    }

    private func listenForResults(from transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        guard let self else { return }
                        self.transcript = text
                        self.deliver(text, isFinal: result.isFinal)
                    }
                }
            } catch {
                await MainActor.run {
                    self?.state = .failed(Self.describe(error))
                }
            }
        }
    }

    /// Manda lo dictado al panel con foco, tecla a tecla.
    ///
    /// Sólo se entrega lo **definitivo**: los resultados provisionales cambian
    /// mientras se habla, y reenviarlos llenaría el terminal de basura.
    private func deliver(_ text: String, isFinal: Bool) {
        guard isFinal, !text.isEmpty else { return }
        AppServices.shared.desktopViewController?.insertText(text)
    }

    // MARK: - Parada

    func stop() {
        Task { [weak self] in
            guard let self else { return }
            try? await self.analyzer?.finalizeAndFinishThroughEndOfInput()
            self.teardown()
            if case .failed = self.state {} else { self.state = .idle }
        }
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        inputBuilder?.finish()
        inputBuilder = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func describe(_ error: any Error) -> String {
        (error as NSError).localizedDescription
    }
}


private extension AVAudioNode {

    /// Único punto donde se instala el tap de audio.
    ///
    /// iOS 27 marcó `installTap(onBus:bufferSize:format:block:)` como obsoleta
    /// en favor de `installTapOnBus:bufferSize:format:error:block:`. **Esa
    /// sustituta no se puede llamar desde Swift en el SDK 27**: comprobado
    /// compilando contra `iphoneos27.0`, pasarle `error:` da "extra arguments
    /// at positions #4, #5", así que Swift sólo importa la vieja. Desambiguar
    /// por tipo tampoco sirve, porque `throws` no cuenta para la resolución de
    /// sobrecargas.
    ///
    /// Así que se usa la obsoleta, que sigue funcionando. Este envoltorio existe
    /// para que el aviso del compilador salga **en un solo sitio** en lugar de
    /// en cada llamada, y para que, cuando Apple lo arregle, no haya que buscar
    /// dónde se tocaba. No se marca `@available(deprecated:)`: eso propagaría el
    /// aviso a quien llame, que es justo lo contrario de lo que se quiere.
    func installBrunOSTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) {
        installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            handler(buffer)
        }
    }
}
