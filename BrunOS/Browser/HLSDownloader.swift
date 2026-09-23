import AVFoundation
import Foundation

/// Descarga los vídeos por trozos (HLS, los `.m3u8`) y los deja como un `.mp4`
/// en Descargas.
///
/// **No se bajan los trozos a mano.** Una lista HLS puede tener varias
/// calidades, pistas de audio aparte, trozos cifrados con AES y, según el
/// sitio, MPEG-TS o MP4 fragmentado; unir `.ts` a pelo da un fichero que el
/// iPhone ni siquiera sabe reproducir. AVFoundation ya sabe hacerlo todo:
/// `AVAssetDownloadURLSession` lo baja entero a un paquete `.movpkg`, y
/// `AVAssetExportSession` lo pasa a `.mp4` sin recodificar.
///
/// Lo que **no** puede: vídeo con DRM (FairPlay: Netflix y compañía) y DASH
/// (`.mpd`), que no es un formato de Apple. YouTube sigue fuera por lo mismo
/// de siempre.
///
/// Las cookies de la pestaña viajan con la petición, para lo que va detrás de
/// un inicio de sesión. El `Referer` no: AVFoundation no deja ponerlo, así que
/// un sitio que proteja su CDN por ahí devolverá error.
@MainActor
final class HLSDownloader: NSObject {

    private struct Job {
        var name: String
        var destination: URL
        var package: URL?
        var observation: NSKeyValueObservation?
        var lastFraction: Double = -1
    }

    private var jobs: [Int: Job] = [:]

    /// Una sesión de fondo, que es lo que exige AVFoundation para bajar HLS.
    /// Se crea al primer uso: no hace falta tenerla viva si nunca se descarga
    /// nada.
    private lazy var session: AVAssetDownloadURLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: (Bundle.main.bundleIdentifier ?? "brunos") + ".hls"
        )
        return AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: .main
        )
    }()

    func download(_ url: URL, named name: String, cookies: [HTTPCookie], userAgent: String?) {
        // Siempre `.mp4`, aunque el nombre sugerido dijera `.m3u8`.
        let base = (name as NSString).deletingPathExtension
        let destination = BrowserTab.uniqueDownloadURL(named: base + ".mp4")

        var options: [String: Any] = [AVURLAssetHTTPCookiesKey: cookies]
        if let userAgent { options[AVURLAssetHTTPUserAgentKey] = userAgent }
        let asset = AVURLAsset(url: url, options: options)

        let configuration = AVAssetDownloadConfiguration(asset: asset, title: base)
        let task = session.makeAssetDownloadTask(downloadConfiguration: configuration)

        var job = Job(name: destination.lastPathComponent, destination: destination)
        let id = task.taskIdentifier
        // Sólo cruzan números al actor principal, como en las descargas
        // normales: `Progress` no es `Sendable`.
        job.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor [weak self] in self?.report(id, fraction: fraction) }
        }
        jobs[id] = job

        AppServices.shared.downloads.begin(name: job.name) { [weak task] in task?.cancel() }
        task.resume()
    }

    private func report(_ id: Int, fraction: Double) {
        guard var job = jobs[id] else { return }
        // Cada punto porcentual y no a cada trozo: repintar tanto se nota en
        // el cursor.
        guard fraction - job.lastFraction >= 0.01 else { return }
        job.lastFraction = fraction
        jobs[id] = job
        // Mientras baja se reserva un 5 % para el paso a `.mp4`.
        AppServices.shared.downloads.progress(name: job.name, fraction: fraction * 0.95, done: 0, total: 0)
    }

    /// Del paquete `.movpkg` a un `.mp4` normal, sin recodificar.
    private func finish(_ id: Int) async {
        guard let job = jobs.removeValue(forKey: id) else { return }
        let downloads = AppServices.shared.downloads
        guard let package = job.package else {
            downloads.fail(name: job.name, reason: "No llegó nada.")
            return
        }
        defer { try? FileManager.default.removeItem(at: package) }

        let asset = AVURLAsset(url: package)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            downloads.fail(name: job.name, reason: "Este vídeo no se puede convertir a mp4.")
            return
        }
        do {
            try await export.export(to: job.destination, as: .mp4)
            downloads.finish(name: job.name, url: job.destination)
        } catch {
            downloads.fail(name: job.name, reason: "No se pudo convertir a mp4: \(error.localizedDescription)")
        }
    }

    private func fail(_ id: Int, error: any Error) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        if let package = job.package { try? FileManager.default.removeItem(at: package) }
        if (error as NSError).code == NSURLErrorCancelled { return }
        AppServices.shared.downloads.fail(name: job.name, reason: error.localizedDescription)
    }
}

// La sesión entrega en la cola principal (`delegateQueue: .main`), así que se
// puede entrar al actor principal sin saltos.
extension HLSDownloader: AVAssetDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        let id = assetDownloadTask.taskIdentifier
        MainActor.assumeIsolated { jobs[id]?.package = location }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let id = task.taskIdentifier
        MainActor.assumeIsolated {
            if let error {
                fail(id, error: error)
            } else {
                Task { await finish(id) }
            }
        }
    }
}
