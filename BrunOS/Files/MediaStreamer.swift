import AVFoundation
import UniformTypeIdentifiers

/// Un origen que sabe leer un trozo suelto de un fichero, sin bajarlo entero.
///
/// Lo cumplen SFTP y SMB. Es lo que deja ver un vídeo del servidor **mientras
/// llega**, en vez de esperar a tenerlo entero (Bruno, 24-sep-2026).
protocol RangeReadableProvider: FileProvider {
    func read(_ path: String, offset: UInt64, length: Int) async throws -> Data
}

/// Reproduce un vídeo o un audio de un servidor pidiéndole sólo lo que el
/// reproductor necesita.
///
/// AVFoundation no sabe hablar SFTP ni SMB, pero deja poner un intermediario:
/// con una dirección de un esquema que no conoce (`brunos-stream://`), pregunta
/// a `AVAssetResourceLoaderDelegate` por cada rango de bytes que quiere, y aquí
/// se lo pedimos al servidor. Así empieza a sonar a los pocos segundos y se
/// puede saltar a cualquier punto sin tener lo de antes.
///
/// En iCloud no hay nada equivalente: la única vía pública es publicar un
/// enlace que cualquiera podría abrir, y eso no se hace.
final class MediaStreamer: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {

    private let provider: any RangeReadableProvider
    private let path: String
    private let size: Int64
    private let contentType: String
    private let queue = DispatchQueue(label: "com.baltamir.brunos.stream")

    /// Lo que se está pidiendo, para cortarlo si el reproductor lo cancela
    /// (al saltar a otro punto cancela lo que ya no quiere). Sólo se toca
    /// desde `queue`.
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Cuánto se pide al servidor de cada vez. Más grande, menos idas y
    /// vueltas; más pequeño, antes llega lo primero.
    private static let chunk = 512 * 1024

    static let scheme = "brunos-stream"

    init(provider: any RangeReadableProvider, item: FileItem) {
        self.provider = provider
        self.path = item.path
        self.size = item.size
        self.contentType = item.type?.identifier ?? UTType.movie.identifier
    }

    /// El recurso que se le da al reproductor. Tiene que conservarse el
    /// `MediaStreamer` mientras se reproduce: el asset sólo lo guarda débil.
    func makeAsset(fileName: String) -> AVURLAsset? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "media"
        components.path = "/" + fileName
        guard let url = components.url else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func cancelAll() {
        queue.async { [self] in
            tasks.values.forEach { $0.cancel() }
            tasks.removeAll()
        }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = size
            information.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let start = UInt64(max(0, dataRequest.currentOffset))
        let wanted: Int64 = dataRequest.requestsAllDataToEndOfResource
            ? size - Int64(start)
            : Int64(dataRequest.requestedLength) - (dataRequest.currentOffset - dataRequest.requestedOffset)
        let end = min(UInt64(size), start + UInt64(max(0, wanted)))

        let id = ObjectIdentifier(loadingRequest)
        let request = UncheckedRequest(loadingRequest)
        // Retiene al cargador mientras dura, y lo suelta al acabar.
        let task = Task { [self, provider, path, queue] in
            var offset = start
            do {
                while offset < end {
                    try Task.checkCancellation()
                    let length = Int(min(UInt64(Self.chunk), end - offset))
                    let data = try await provider.read(path, offset: offset, length: length)
                    guard !data.isEmpty else { break }
                    queue.async { request.value.dataRequest?.respond(with: data) }
                    offset += UInt64(data.count)
                }
                queue.async { request.value.finishLoading() }
            } catch is CancellationError {
                // Lo ha cancelado el reproductor: no hay nada que decirle.
            } catch {
                queue.async { request.value.finishLoading(with: error) }
            }
            queue.async { self.tasks[id] = nil }
        }
        tasks[id] = task
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let id = ObjectIdentifier(loadingRequest)
        tasks[id]?.cancel()
        tasks[id] = nil
    }
}

/// `AVAssetResourceLoadingRequest` no es `Sendable`, pero sólo se toca desde
/// la cola del cargador, que es la que AVFoundation dice.
private struct UncheckedRequest: @unchecked Sendable {
    let value: AVAssetResourceLoadingRequest
    init(_ value: AVAssetResourceLoadingRequest) { self.value = value }
}
