import UIKit

/// Los iconos de los sitios, para la barra de favoritos, el lanzador y la
/// página de inicio.
///
/// **Se piden al propio sitio**, nunca a un servicio de iconos de terceros: un
/// `https://sitio/favicon.ico` lo ve sólo ese sitio, mientras que los
/// servicios tipo «dame el icono de este dominio» son una lista de todo lo que
/// hay en los favoritos entregada a un extraño.
///
/// Se guardan en Application Support ya reducidos, uno por dominio. Un icono
/// que no está no se vuelve a pedir en toda la sesión: hay webs sin favicon, y
/// reintentar en cada repintado sería una petición por fotograma.
@MainActor
final class FaviconStore {

    /// Alguien ha conseguido un icono nuevo: lo que lo dibuje, que se repinte.
    static let didChange = Notification.Name("BrunOSFaviconDidChange")

    /// Tamaño al que se guardan. 32 puntos es el doble de lo que mide en la
    /// barra, para que se vea nítido en un monitor a escala.
    private static let side: CGFloat = 32

    private var memory: [String: UIImage] = [:]
    private var missing: Set<String> = []
    private var inFlight: Set<String> = []

    private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// El icono del sitio, si ya se tiene. Si no, se pide y se avisa al
    /// llegar: **esto lo llama un `draw(_:)`** y no puede esperar a la red.
    func icon(for host: String?) -> UIImage? {
        guard let host, !host.isEmpty else { return nil }
        if let image = memory[host] { return image }

        let file = directory.appendingPathComponent(host + ".png")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory[host] = image
            return image
        }

        download(host: host, from: nil)
        return nil
    }

    /// La página ha dicho cuál es su icono (`<link rel="icon">`). Se prefiere
    /// al `/favicon.ico` de siempre: muchos sitios ya no tienen ese fichero.
    func remember(host: String?, iconURL: String?) {
        guard let host, !host.isEmpty, memory[host] == nil else { return }
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(host + ".png").path)
        else { return }
        missing.remove(host)
        download(host: host, from: iconURL.flatMap(URL.init(string:)))
    }

    private func download(host: String, from declared: URL?) {
        guard !missing.contains(host), !inFlight.contains(host) else { return }
        var candidates: [URL] = []
        if let declared { candidates.append(declared) }
        if let fallback = URL(string: "https://\(host)/favicon.ico") { candidates.append(fallback) }
        guard !candidates.isEmpty else { return }

        inFlight.insert(host)
        Task { [weak self] in
            let data = await Self.firstIcon(of: candidates)
            guard let self else { return }
            self.inFlight.remove(host)
            guard let data, let image = UIImage(data: data)?.scaled(to: Self.side) else {
                self.missing.insert(host)
                return
            }
            self.memory[host] = image
            if let png = image.pngData() {
                try? png.write(to: self.directory.appendingPathComponent(host + ".png"), options: .atomic)
            }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    /// Fuera del actor: la red no tiene por qué pasar por el hilo principal, y
    /// lo que vuelve es `Data`, que sí se puede cruzar sin problemas.
    private nonisolated static func firstIcon(of candidates: [URL]) async -> Data? {
        for url in candidates {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  // Un servidor que no tiene el icono suele devolver su página
                  // de error con código 200: si no pesa nada o es HTML, no vale.
                  data.count > 50, data.count < 512 * 1024
            else { continue }
            return data
        }
        return nil
    }
}

extension UIImage {
    /// Cuadrado de lado `side`, sin deformar: los favicons vienen en todos los
    /// tamaños y algunos no son cuadrados.
    func scaled(to side: CGFloat) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let canvas = CGSize(width: side, height: side)
        let factor = min(side / size.width, side / size.height)
        let target = CGSize(width: size.width * factor, height: size.height * factor)
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            draw(in: CGRect(
                x: (side - target.width) / 2,
                y: (side - target.height) / 2,
                width: target.width,
                height: target.height
            ))
        }
    }
}
