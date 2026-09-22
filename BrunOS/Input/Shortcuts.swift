import UIKit

/// Órdenes del gestor de ventanas.
///
/// **Cmd es el modificador del escritorio; Ctrl y Option no se tocan nunca**,
/// porque son del terminal: un Ctrl+C que se quedara por el camino haría la app
/// inservible para lo que se hizo.
///
/// iOS se reserva Cmd+Tab, Cmd+Espacio y Cmd+H, así que esas no se pueden usar.
enum DesktopCommand: Equatable {
    case switchWorkspace(Int)
    case moveFocus(TilingLayout.Direction)
    case movePane(TilingLayout.Direction)
    case toggleMaximize
    case toggleFullScreen
    case toggleFloating
    case newTab
    case closeTab
    case newPane
    case launcher
    case copy
    case paste
    case addressBar
    case reload
    case find
    case zoomIn
    case zoomOut
    case zoomReset

    /// Lo que se rotula en la ayuda y en los ajustes.
    var label: String {
        switch self {
        case .switchWorkspace(let n): "Ir al espacio \(n)"
        case .moveFocus: "Mover el foco"
        case .movePane: "Mover el panel"
        case .toggleMaximize: "Maximizar o restaurar"
        case .toggleFullScreen: "Pantalla completa"
        case .toggleFloating: "Flotar o volver al mosaico"
        case .newTab: "Nueva pestaña o sesión"
        case .closeTab: "Cerrar pestaña o sesión"
        case .newPane: "Nuevo panel"
        case .launcher: "Lanzador"
        case .copy: "Copiar"
        case .paste: "Pegar"
        case .addressBar: "Barra de direcciones"
        case .reload: "Recargar"
        case .find: "Buscar"
        case .zoomIn: "Aumentar"
        case .zoomOut: "Reducir"
        case .zoomReset: "Tamaño normal"
        }
    }
}

/// Tabla de atajos, en un sitio y sólo en uno.
enum Shortcuts {

    /// Descripción declarativa de cada atajo, de la que salen tanto los
    /// `UIKeyCommand` que se registran como la ayuda que se enseña.
    struct Entry {
        var input: String
        var modifiers: UIKeyModifierFlags
        var command: DesktopCommand
        var title: String
    }

    static let all: [Entry] = {
        var entries: [Entry] = []

        for number in 1...3 {
            entries.append(Entry(
                input: "\(number)",
                modifiers: .command,
                command: .switchWorkspace(number),
                title: "Espacio \(number)"
            ))
        }

        let arrows: [(String, TilingLayout.Direction)] = [
            (UIKeyCommand.inputLeftArrow, .left),
            (UIKeyCommand.inputRightArrow, .right),
            (UIKeyCommand.inputUpArrow, .up),
            (UIKeyCommand.inputDownArrow, .down),
        ]
        for (input, direction) in arrows {
            entries.append(Entry(
                input: input,
                modifiers: [.command, .alternate],
                command: .moveFocus(direction),
                title: "Mover el foco"
            ))
            entries.append(Entry(
                input: input,
                modifiers: [.command, .shift],
                command: .movePane(direction),
                title: "Mover el panel"
            ))
        }

        entries += [
            Entry(input: "\r", modifiers: .command, command: .toggleMaximize, title: "Maximizar"),
            // Como en macOS. Va antes que Cmd+F, que es buscar.
            Entry(input: "f", modifiers: [.command, .control], command: .toggleFullScreen,
                  title: "Pantalla completa"),
            // Mod+Mayús+Espacio es el de i3 para lo mismo.
            Entry(input: " ", modifiers: [.command, .shift], command: .toggleFloating,
                  title: "Flotar"),
            Entry(input: "t", modifiers: .command, command: .newTab, title: "Nueva pestaña"),
            Entry(input: "w", modifiers: .command, command: .closeTab, title: "Cerrar pestaña"),
            Entry(input: "n", modifiers: .command, command: .newPane, title: "Nuevo panel"),
            Entry(input: "p", modifiers: .command, command: .launcher, title: "Lanzador"),
            // Cmd+C y Cmd+V **tienen que estar aquí**. Sin declararlos, el
            // router los dejaba pasar al panel y el terminal acababa mandando
            // una "c" al servidor en vez de copiar.
            Entry(input: "c", modifiers: .command, command: .copy, title: "Copiar"),
            Entry(input: "v", modifiers: .command, command: .paste, title: "Pegar"),
            Entry(input: "l", modifiers: .command, command: .addressBar, title: "Dirección"),
            Entry(input: "r", modifiers: .command, command: .reload, title: "Recargar"),
            Entry(input: "f", modifiers: .command, command: .find, title: "Buscar"),
            Entry(input: "+", modifiers: .command, command: .zoomIn, title: "Aumentar"),
            Entry(input: "=", modifiers: .command, command: .zoomIn, title: "Aumentar"),
            Entry(input: "-", modifiers: .command, command: .zoomOut, title: "Reducir"),
            Entry(input: "0", modifiers: .command, command: .zoomReset, title: "Tamaño normal"),
        ]

        return entries
    }()

    /// Busca qué orden corresponde a una combinación concreta.
    static func command(input: String, modifiers: UIKeyModifierFlags) -> DesktopCommand? {
        // Se comparan sólo los modificadores que importan: iOS añade banderas
        // como `.numericPad` en las flechas y estropearían una igualdad exacta.
        let relevant: UIKeyModifierFlags = [.command, .alternate, .shift, .control]
        let clean = modifiers.intersection(relevant)
        return all.first { $0.input == input && $0.modifiers == clean }?.command
    }
}
