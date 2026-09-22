import Observation
import UIKit

/// Fondo del escritorio.
///
/// **El fondo del iPhone no se puede leer.** No existe API pública para
/// obtenerlo: iOS no se lo enseña a las apps, y no es un descuido sino una
/// decisión de privacidad. Comprobado en el SDK de iOS 27. Así que BrunOS trae
/// los suyos.
///
/// Hay dos clases, y la diferencia importa:
///
/// - Los **degradados** se dibujan por código. No pesan nada, se adaptan a
///   cualquier resolución sin pixelarse y **van siempre**, también en un clon
///   recién hecho del repositorio.
/// - Las **imágenes** las copia `Tools/fetch-wallpapers.sh` desde los fondos de
///   macOS del propio Mac. **No se versionan**: son de Apple y redistribuirlas
///   en un repositorio público no procede. Quien clone esto y las quiera,
///   ejecuta el script.
///
/// Pendiente para la Fase 4: elegir una imagen cualquiera desde el gestor de
/// ficheros. El caso `.file` ya está previsto para eso.
enum Wallpaper: Codable, Equatable, Sendable {
    case solid
    case gradient(Gradient)
    /// Nombre del fichero dentro de `Resources/Wallpapers`.
    case image(String)
    /// Imagen elegida desde el gestor de ficheros (Fase 4). Se guarda un
    /// marcador de seguridad, no una ruta: las carpetas externas de iOS no
    /// siguen siendo accesibles entre sesiones sin él.
    case file(bookmark: Data)

    /// Degradados propios.
    ///
    /// No son degradados lineales a secas: llevan **un resplandor radial
    /// encima**, que es lo que da el aire de los fondos de Apple. Un degradado
    /// plano de dos colores se nota plano enseguida en un monitor grande.
    ///
    /// Todos son oscuros a propósito: encima van paneles con texto, y un fondo
    /// claro deja el escritorio ilegible.
    enum Gradient: String, Codable, CaseIterable, Sendable {
        case goldenGate
        case ember
        case abyss
        case slate
        case moss
        case dusk

        var label: String {
            switch self {
            case .goldenGate: "Golden Gate"
            case .ember: "Brasa"
            case .abyss: "Abismo"
            case .slate: "Pizarra"
            case .moss: "Musgo"
            case .dusk: "Ocaso"
            }
        }

        /// Degradado de base, de arriba abajo.
        var colors: [UIColor] {
            switch self {
            case .goldenGate:
                // Atardecer: cielo alto azulado, bruma cálida y agua oscura.
                [
                    UIColor(hex: 0x1B1220),
                    UIColor(hex: 0x3A1E1C),
                    UIColor(hex: 0x6B3415),
                    UIColor(hex: 0x24140E),
                ]
            case .ember:
                [UIColor(hex: 0x1A1109), UIColor(hex: 0x2E1B0B), UIColor(hex: 0x0B0D10)]
            case .abyss:
                [UIColor(hex: 0x05070D), UIColor(hex: 0x0B1524), UIColor(hex: 0x081019)]
            case .slate:
                [UIColor(hex: 0x14171B), UIColor(hex: 0x1D2228), UIColor(hex: 0x0E1114)]
            case .moss:
                [UIColor(hex: 0x0A140F), UIColor(hex: 0x12241C), UIColor(hex: 0x0A0F0C)]
            case .dusk:
                [UIColor(hex: 0x120B1A), UIColor(hex: 0x1F1330), UIColor(hex: 0x0C0812)]
            }
        }

        /// El resplandor: color, dónde cae y cuánto ocupa.
        ///
        /// En Golden Gate va bajo y a la izquierda, como un sol a punto de
        /// meterse; en los demás es una luz suave que rompe la uniformidad.
        var glow: (color: UIColor, center: CGPoint, radius: CGFloat) {
            switch self {
            case .goldenGate: (UIColor(hex: 0xE8853D), CGPoint(x: 0.24, y: 0.72), 0.62)
            case .ember: (UIColor(hex: 0xE8A33D), CGPoint(x: 0.5, y: 0.85), 0.55)
            case .abyss: (UIColor(hex: 0x2E6C9E), CGPoint(x: 0.72, y: 0.25), 0.60)
            case .slate: (UIColor(hex: 0x4A5763), CGPoint(x: 0.5, y: 0.4), 0.70)
            case .moss: (UIColor(hex: 0x4FB3A3), CGPoint(x: 0.3, y: 0.7), 0.50)
            case .dusk: (UIColor(hex: 0x8A5CC4), CGPoint(x: 0.7, y: 0.6), 0.55)
            }
        }

        /// Cuánto se deja ver el resplandor. Discreto: es un fondo, no un
        /// cuadro, y debajo hay que poder leer.
        var glowOpacity: Float {
            self == .goldenGate ? 0.40 : 0.26
        }
    }

    var label: String {
        switch self {
        case .solid: "Liso"
        case .gradient(let value): value.label
        case .image(let name): Self.prettyName(for: name)
        case .file: "Imagen propia"
        }
    }

    /// `Big Sur Graphic.heic` → `Big Sur Graphic`.
    static func prettyName(for file: String) -> String {
        (file as NSString).deletingPathExtension
    }
}

/// Elige, guarda y pinta el fondo.
@MainActor
@Observable
final class WallpaperStore {

    private static let key = "display.wallpaper"

    var current: Wallpaper {
        didSet {
            guard current != oldValue else { return }
            save()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    static let didChangeNotification = Notification.Name("BrunOSWallpaperDidChange")

    /// Lo que se puede elegir: los degradados siempre, más las imágenes que
    /// haya dejado el script.
    var available: [Wallpaper] {
        var result: [Wallpaper] = Wallpaper.Gradient.allCases.map { .gradient($0) }
        result.append(.solid)
        result += imageNames.map { .image($0) }
        return result
    }

    private(set) var imageNames: [String] = []

    /// Lo último que se pintó, para no repetir trabajo.
    ///
    /// **Esto no es una optimización, es lo que evitaba que la app muriera.**
    /// `apply` se llamaba en cada pasada de layout del escritorio, o sea en cada
    /// clic, y con un fondo de imagen eso significaba **volver a decodificar un
    /// HEIC de 3840 px cada vez**. Unos cuantos clics seguidos y iOS mataba la
    /// app por consumo de memoria.
    private var lastApplied: (wallpaper: Wallpaper, size: CGSize)?

    /// La imagen ya decodificada. Decodificar un HEIC grande cuesta caro.
    private var cachedImage: (name: String, image: UIImage)?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(Wallpaper.self, from: data) {
            current = stored
        } else {
            current = .gradient(.goldenGate)
        }
        reloadImages()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(current) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private func reloadImages() {
        let urls = Bundle.main.urls(
            forResourcesWithExtension: nil,
            subdirectory: "Wallpapers"
        ) ?? []
        imageNames = urls
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".heic") || $0.hasSuffix(".jpg") }
            .sorted()
    }

    // MARK: - Dibujo

    /// Obliga a repintar en la próxima pasada, aunque no haya cambiado ni el
    /// fondo ni el tamaño. Lo pide el cambio de claro a oscuro.
    func invalidate() {
        lastApplied = nil
    }

    /// Prepara la capa de fondo para un tamaño dado.
    ///
    /// Se pinta en capas y no con una `UIImageView` para poder mezclar
    /// degradados, resplandores e imágenes sin rehacer la jerarquía de vistas.
    func apply(to layer: CALayer, size: CGSize) {
        // Si no ha cambiado ni el fondo ni el tamaño, no hay nada que rehacer.
        if let lastApplied, lastApplied.wallpaper == current, lastApplied.size == size {
            return
        }
        lastApplied = (current, size)

        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer.backgroundColor = Tokens.Color.background.desktopCGColor
        let bounds = CGRect(origin: .zero, size: size)

        switch current {
        case .solid:
            return

        case .gradient(let gradient):
            let base = CAGradientLayer()
            base.frame = bounds
            base.colors = gradient.colors.map(\.cgColor)
            base.startPoint = CGPoint(x: 0.5, y: 0)
            base.endPoint = CGPoint(x: 0.5, y: 1)
            layer.addSublayer(base)

            let (color, center, radius) = gradient.glow
            let glow = CAGradientLayer()
            glow.type = .radial
            glow.frame = bounds
            glow.colors = [
                color.withAlphaComponent(1).cgColor,
                color.withAlphaComponent(0).cgColor,
            ]
            glow.startPoint = center
            // En un degradado radial, `endPoint` marca el borde del círculo.
            glow.endPoint = CGPoint(x: center.x + radius, y: center.y + radius)
            glow.opacity = gradient.glowOpacity
            layer.addSublayer(glow)

        case .image(let name):
            guard let image = loadImage(named: name) else {
                fallBackToGradient(layer: layer, bounds: bounds)
                return
            }
            addImageLayers(image, to: layer, bounds: bounds)

        case .file(let bookmark):
            guard let image = loadImage(fromBookmark: bookmark) else {
                fallBackToGradient(layer: layer, bounds: bounds)
                return
            }
            addImageLayers(image, to: layer, bounds: bounds)
        }
    }

    /// La imagen ya no está: se pinta un degradado en su lugar.
    ///
    /// **El cambio de `current` va aplazado a propósito.** Hacerlo aquí dentro
    /// dispararía la notificación de cambio, que provoca otra pasada de layout,
    /// que vuelve a llamar a `apply`, que vuelve a no encontrar la imagen:
    /// recursión infinita y la app al suelo.
    private func fallBackToGradient(layer: CALayer, bounds: CGRect) {
        let gradient = Wallpaper.Gradient.goldenGate
        let base = CAGradientLayer()
        base.frame = bounds
        base.colors = gradient.colors.map(\.cgColor)
        base.startPoint = CGPoint(x: 0.5, y: 0)
        base.endPoint = CGPoint(x: 0.5, y: 1)
        layer.addSublayer(base)

        Task { @MainActor [weak self] in
            self?.current = .gradient(gradient)
        }
    }

    private func addImageLayers(_ image: UIImage, to layer: CALayer, bounds: CGRect) {
        let imageLayer = CALayer()
        imageLayer.frame = bounds
        imageLayer.contents = image.cgImage
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        layer.addSublayer(imageLayer)

        // Un velo oscuro encima. Los fondos de macOS son luminosos, y sobre un
        // cielo claro se pierden el texto de la barra y los bordes de los
        // paneles. En modo claro, la barra y los paneles ya son claros y el
        // velo sólo apagaría la foto: se deja en un toque.
        let veil = CALayer()
        veil.frame = bounds
        let dimming: CGFloat = DesktopTheme.style == .dark ? 0.35 : 0.08
        veil.backgroundColor = UIColor.black.withAlphaComponent(dimming).cgColor
        layer.addSublayer(veil)
    }

    private func loadImage(named name: String) -> UIImage? {
        if let cachedImage, cachedImage.name == name { return cachedImage.image }
        guard let url = Bundle.main.url(
            forResource: (name as NSString).deletingPathExtension,
            withExtension: (name as NSString).pathExtension,
            subdirectory: "Wallpapers"
        ) else { return nil }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cachedImage = (name, image)
        return image
    }

    /// Abre una imagen elegida desde el gestor de ficheros.
    ///
    /// Hace falta el marcador de seguridad: en iOS, una carpeta de fuera del
    /// contenedor de la app deja de ser accesible en la sesión siguiente si no
    /// se guarda así.
    private func loadImage(fromBookmark bookmark: Data) -> UIImage? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            bookmarkDataIsStale: &isStale
        ), url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return UIImage(contentsOfFile: url.path)
    }
}
