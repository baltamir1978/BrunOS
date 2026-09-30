import UIKit

/// Las apps del dock.
enum PaneKind: String, CaseIterable, Sendable {
    case terminal
    case browser
    case files
    case notes
    case photos

    /// De qué app es un panel ya creado. Lo usa el dock para dibujar el
    /// icono de los minimizados. `nil` para lo que no es una app del dock,
    /// como la ventana de Ajustes: antes caía en `.terminal` y habría
    /// encendido su punto.
    @MainActor
    static func of(_ pane: any Pane) -> PaneKind? {
        switch pane {
        case is TerminalPane: .terminal
        case is BrowserPane: .browser
        case is FilesPane: .files
        case is NotesPane: .notes
        case is PhotosPane: .photos
        default: nil
        }
    }

    /// El orden de los iconos del dock: el de siempre, web · ssh · ficheros,
    /// y detrás las notas (Cmd+4) y las fotos (Cmd+5).
    static let dockOrder: [PaneKind] = [.browser, .terminal, .files, .notes, .photos]

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .browser: "Navegador"
        case .files: "Ficheros"
        case .notes: "Notas"
        case .photos: "Fotos"
        }
    }

    /// Icono del dock. Símbolos del sistema: se ven nítidos a cualquier escala
    /// y no hay que dibujar ni mantener nada.
    var symbol: String {
        switch self {
        case .terminal: "apple.terminal.fill"
        case .browser: "globe"
        case .files: "folder.fill"
        case .notes: "note.text"
        case .photos: "photo.on.rectangle"
        }
    }
}
