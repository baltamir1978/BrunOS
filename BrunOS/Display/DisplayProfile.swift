import CoreGraphics
import Foundation

/// Ajustes de una pantalla externa concreta.
///
/// iOS no expone el EDID, así que no hay forma de identificar el monitor por
/// número de serie ni por nombre. Se identifica por su resolución nativa en
/// píxeles, que en la práctica basta: no es habitual tener dos pantallas
/// distintas con exactamente el mismo modo de vídeo.
struct DisplayProfile: Codable, Equatable, Sendable {

    /// Escala de interfaz, al estilo de las resoluciones escaladas de macOS.
    /// La resolución lógica es `píxeles nativos / escala`, y todo el escritorio
    /// se maqueta en ese espacio y se renderiza nítido a resolución nativa.
    enum Scale: Double, Codable, CaseIterable, Sendable {
        case x1 = 1.0
        case x1_5 = 1.5
        case x2 = 2.0
        case x2_5 = 2.5
        case x3 = 3.0

        var label: String {
            switch self {
            case .x1: "1×"
            case .x1_5: "1,5×"
            case .x2: "2×"
            case .x2_5: "2,5×"
            case .x3: "3×"
            }
        }
    }

    /// Margen manual por lado, como fracción del ancho o alto.
    ///
    /// `overscanCompensation` de UIKit se deja siempre en `.none` porque en las
    /// teles suele recortar de más o escalar la imagen. Este margen lo aplica
    /// BrunOS dentro de su propio espacio lógico, así que no pierde nitidez.
    enum Overscan: Double, Codable, CaseIterable, Sendable {
        case none = 0
        case small = 0.025
        case large = 0.05

        var label: String {
            switch self {
            case .none: "0 %"
            case .small: "2,5 %"
            case .large: "5 %"
            }
        }
    }

    /// Resolución nativa en píxeles, que hace de identificador de la pantalla.
    var nativePixelWidth: Int
    var nativePixelHeight: Int
    var scale: Scale
    var overscan: Overscan

    /// Clave estable para `UserDefaults`.
    var key: String { "\(nativePixelWidth)x\(nativePixelHeight)" }

    static func key(forNativePixels size: CGSize) -> String {
        "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    /// Escala por defecto para una pantalla recién vista.
    ///
    /// Se busca una resolución lógica cómoda para un escritorio de texto: en un
    /// 4K, 2× deja 1920×1080 lógicos; en un 1080p, 1× lo deja tal cual.
    static func makeDefault(nativePixels size: CGSize) -> DisplayProfile {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        let scale: Scale = if width >= 3_000 {
            .x2
        } else if width >= 2_000 {
            .x1_5
        } else {
            .x1
        }
        return DisplayProfile(
            nativePixelWidth: width,
            nativePixelHeight: height,
            scale: scale,
            overscan: .none
        )
    }

    /// Tamaño del escritorio en puntos lógicos, ya descontado el overscan.
    var logicalSize: CGSize {
        let full = CGSize(
            width: Double(nativePixelWidth) / scale.rawValue,
            height: Double(nativePixelHeight) / scale.rawValue
        )
        let inset = overscan.rawValue
        return CGSize(
            width: full.width * (1 - 2 * inset),
            height: full.height * (1 - 2 * inset)
        )
    }

    /// Cómo se describe en la barra superior: `1920×1080 · 2×`.
    var summary: String {
        let size = logicalSize
        return "\(Int(size.width.rounded()))×\(Int(size.height.rounded())) · \(scale.label)"
    }
}

/// Guarda y recupera el perfil de cada pantalla vista, para aplicarlo al
/// reconectar sin que Bruno tenga que volver a ajustar nada.
struct DisplayProfileStore {

    private let defaults: UserDefaults
    private let prefix = "display.profile."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func profile(forNativePixels size: CGSize) -> DisplayProfile {
        let key = prefix + DisplayProfile.key(forNativePixels: size)
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(DisplayProfile.self, from: data)
        else {
            return .makeDefault(nativePixels: size)
        }
        return stored
    }

    func save(_ profile: DisplayProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: prefix + profile.key)
    }
}
