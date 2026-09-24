import AVFoundation
import ImageIO
import PDFKit
import UIKit

/// Vista previa con la barra espaciadora, como en macOS.
///
/// **No usa `QLPreviewController` a propósito.** QuickLook está pensado para
/// presentarse como pantalla modal y espera toques del sistema; en la pantalla
/// externa no hay ni una cosa ni la otra, así que se queda sordo. Este visor se
/// dibuja como una vista más del escritorio y recibe el ratón por donde lo
/// recibe todo lo demás.
///
/// Cubre imágenes, GIF animados, vídeo, audio, PDF y texto. Lo que no entienda
/// lo dice claramente en vez de enseñar un rectángulo vacío.
@MainActor
final class QuickLookView: UIView {

    var onDismiss: (() -> Void)?

    private let item: FileItem
    /// De dónde es: cada ventana de Ficheros puede estar en una ubicación.
    private let provider: any FileProvider
    private let card = UIView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let content = UIView()
    private let statusLabel = UILabel()

    /// Se conserva para poder pararlo: un vídeo que sigue sonando después de
    /// cerrar la vista previa es de lo más molesto que hay.
    private var player: AVPlayer?
    private var animationTask: Task<Void, Never>?

    init(item: FileItem, provider: any FileProvider, frame: CGRect) {
        self.item = item
        self.provider = provider
        super.init(frame: frame)

        backgroundColor = UIColor.black.withAlphaComponent(0.6)

        card.backgroundColor = Tokens.Color.panelElevated
        card.layer.cornerRadius = 14
        card.layer.borderWidth = 1
        card.setThemedBorder(Tokens.Color.border)
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.55
        card.layer.shadowRadius = 30
        card.layer.shadowOffset = CGSize(width: 0, height: 12)
        card.clipsToBounds = false
        addSubview(card)

        titleLabel.font = Tokens.sans(15, weight: .semibold)
        titleLabel.textColor = Tokens.Color.text
        titleLabel.text = item.name
        titleLabel.lineBreakMode = .byTruncatingMiddle
        card.addSubview(titleLabel)

        detailLabel.font = Tokens.mono(11)
        detailLabel.textColor = Tokens.Color.textSecondary
        detailLabel.text = "\(item.sizeLabel) · \(item.modifiedLabel)"
        card.addSubview(detailLabel)

        content.backgroundColor = Tokens.Color.background
        content.layer.cornerRadius = 8
        content.clipsToBounds = true
        card.addSubview(content)

        statusLabel.font = Tokens.sans(13)
        statusLabel.textColor = Tokens.Color.textSecondary
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        content.addSubview(statusLabel)

        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    deinit {
        // `deinit` no está aislado, así que el reproductor se para desde el
        // actor principal en cuanto se pueda.
        let player = self.player
        Task { @MainActor in player?.pause() }
    }

    // MARK: - Carga

    private func load() {
        // Lo que está en una nube o en un servidor hay que bajarlo antes: que
        // se vea qué se está esperando, y cuánto, en vez de una pantalla vacía.
        if let external = provider as? ExternalFolderProvider, external.needsDownload(item.path) {
            statusLabel.text = "Bajando de \(external.name)…" + sizeNote
        } else if !(provider is LocalProvider) {
            statusLabel.text = "Bajando…" + sizeNote
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.provider.localURL(for: self.item)
                self.present(url)
            } catch {
                self.statusLabel.text = error.localizedDescription
            }
        }
    }

    private var sizeNote: String {
        guard item.size > 0 else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        return item.size > 100_000_000 ? "\n\(size): puede tardar un rato." : " (\(size))"
    }

    private func present(_ url: URL) {
        switch item.kind {
        case .image:
            presentImage(url)
        case .media:
            presentMedia(url)
        case .pdf:
            presentPDF(url)
        case .text:
            presentText(url)
        case .folder:
            statusLabel.text = "Es una carpeta."
        case .other:
            statusLabel.text = "No hay vista previa para este tipo de fichero.\n"
                + "Se puede abrir desde la app Archivos del iPhone."
        }
    }

    private func presentImage(_ url: URL) {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.frame = content.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.addSubview(imageView)
        statusLabel.isHidden = true

        // Los GIF animados hay que animarlos a mano: `UIImage` sólo se queda
        // con el primer fotograma.
        if item.type == .gif || (item.name as NSString).pathExtension.lowercased() == "gif" {
            animate(url, in: imageView)
        } else {
            imageView.image = UIImage(contentsOfFile: url.path)
        }
    }

    /// Reproduce un GIF cuadro a cuadro respetando sus tiempos.
    private func animate(_ url: URL, in imageView: UIImageView) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else {
            imageView.image = UIImage(contentsOfFile: url.path)
            return
        }

        var frames: [UIImage] = []
        var total: TimeInterval = 0
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cgImage))

            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.1
            // Los GIF con retardo 0 los interpreta todo el mundo como 0,1 s.
            total += delay < 0.011 ? 0.1 : delay
        }

        imageView.animationImages = frames
        imageView.animationDuration = total
        imageView.animationRepeatCount = 0
        imageView.startAnimating()
    }

    private func presentMedia(_ url: URL) {
        let player = AVPlayer(url: url)
        self.player = player

        let layer = AVPlayerLayer(player: player)
        layer.frame = content.bounds
        layer.videoGravity = .resizeAspect
        content.layer.addSublayer(layer)
        statusLabel.isHidden = true

        player.play()
    }

    private func presentPDF(_ url: URL) {
        let view = PDFView(frame: content.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.backgroundColor = Tokens.Color.background
        content.addSubview(view)
        statusLabel.isHidden = true
    }

    private func presentText(_ url: URL) {
        // Sólo los primeros 200 KB: un log de medio giga colgaría la interfaz
        // mientras se maqueta entero, y para ojearlo sobra con el principio.
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 200_000),
              let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            statusLabel.text = "No se pudo leer el texto."
            return
        }
        try? handle.close()

        let textView = UITextView(frame: content.bounds)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.isEditable = false
        textView.backgroundColor = Tokens.Color.background
        textView.textColor = Tokens.Color.text
        textView.font = Tokens.mono(12)
        textView.text = text
        content.addSubview(textView)
        statusLabel.isHidden = true
    }

    // MARK: - Maquetación

    override func layoutSubviews() {
        super.layoutSubviews()

        let width = min(bounds.width * 0.72, 1_100)
        let height = min(bounds.height * 0.78, 760)
        card.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )

        titleLabel.frame = CGRect(x: 18, y: 14, width: width - 36, height: 20)
        detailLabel.frame = CGRect(x: 18, y: 36, width: width - 36, height: 14)
        content.frame = CGRect(x: 14, y: 58, width: width - 28, height: height - 72)
        statusLabel.frame = content.bounds
        player?.currentItem.map { _ in
            content.layer.sublayers?.first?.frame = content.bounds
        }
    }

    // MARK: - Entrada

    /// Cualquier clic la cierra, como el QuickLook de macOS.
    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) -> Bool {
        if case .down = kind { dismiss() }
        return true
    }

    /// La espaciadora y Esc cierran; lo demás se traga para que no se cuele.
    func handleKey(_ event: KeyEvent) -> Bool {
        guard event.phase == .down else { return true }
        switch event.key.keyCode {
        case .keyboardSpacebar, .keyboardEscape, .keyboardReturnOrEnter:
            dismiss()
        default:
            break
        }
        return true
    }

    private func dismiss() {
        player?.pause()
        player = nil
        animationTask?.cancel()
        onDismiss?()
    }
}
