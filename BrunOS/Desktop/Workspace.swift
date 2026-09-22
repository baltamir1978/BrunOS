import CoreGraphics
import UIKit

/// Un espacio de trabajo: su mosaico, sus paneles y cuál tiene el foco.
///
/// BrunOS tiene tres fijos, con una vocación cada uno (`1 web`, `2 ssh`,
/// `3 files`), pero nada impide meter cualquier tipo de panel en cualquiera:
/// el nombre es una etiqueta, no una restricción.
@MainActor
final class Workspace {

    let index: Int
    let name: String

    var layout = TilingLayout()
    private(set) var panes: [PaneID: any Pane] = [:]
    var focused: PaneID?

    /// Paneles mandados al dock con el botón amarillo, en el orden en que se
    /// minimizaron. Siguen vivos —la sesión SSH, la página—, sólo que fuera
    /// del mosaico.
    private(set) var minimized: [(id: PaneID, pane: any Pane)] = []

    init(index: Int, name: String) {
        self.index = index
        self.name = name
    }

    var isEmpty: Bool { panes.isEmpty }

    var focusedPane: (any Pane)? {
        guard let focused else { return nil }
        return panes[focused]
    }

    func pane(_ id: PaneID) -> (any Pane)? {
        panes[id]
    }

    /// Añade un panel partiendo el hueco del que tiene el foco, y le pasa el foco.
    func add(_ pane: any Pane, id: PaneID, focusedFrame: CGRect?) {
        panes[id] = pane
        layout.insert(id, nextTo: focused, focusedFrame: focusedFrame)
        setFocus(id)
    }

    /// Quita un panel y pasa el foco a otro, si queda alguno.
    func remove(_ id: PaneID) {
        panes[id]?.view.removeFromSuperview()
        panes[id] = nil
        layout.remove(id)
        if focused == id {
            setFocus(layout.panes.first)
        }
    }

    func setFocus(_ id: PaneID?) {
        if let previous = focused, let pane = panes[previous] {
            pane.setFocused(false)
        }
        focused = id
        if let id, let pane = panes[id] {
            pane.setFocused(true)
        }
    }

    /// Saca un panel del mosaico y lo deja en el dock.
    func minimize(_ id: PaneID) {
        guard let pane = panes[id] else { return }
        if layout.maximized == id { layout.maximized = nil }
        pane.setFocused(false)
        pane.view.removeFromSuperview()
        panes[id] = nil
        layout.remove(id)
        minimized.append((id, pane))
        if focused == id {
            focused = nil
            setFocus(layout.panes.first)
        }
    }

    /// Lo devuelve al mosaico, junto al panel con foco, y le da el foco.
    func restore(_ id: PaneID, focusedFrame: CGRect?) {
        guard let index = minimized.firstIndex(where: { $0.id == id }) else { return }
        let entry = minimized.remove(at: index)
        add(entry.pane, id: entry.id, focusedFrame: focusedFrame)
    }

    /// Alterna el panel maximizado. Es el *fullscreen* de i3: ocupa todo el
    /// espacio del escritorio, no se convierte en ventana flotante.
    func toggleMaximize() {
        guard let focused else { return }
        layout.maximized = layout.maximized == focused ? nil : focused
    }
}

/// Estado completo del escritorio: los tres espacios y cuál se está viendo.
///
/// Vive en la escena del iPhone, porque es la que recibe el teclado y el ratón,
/// pero lo que dibuja está en la externa. El estado **sobrevive a desconectar
/// el monitor**: al volver a enchufarlo todo reaparece como estaba.
@MainActor
final class DesktopModel {

    static let didChangeNotification = Notification.Name("BrunOSDesktopDidChange")

    let workspaces: [Workspace] = [
        Workspace(index: 1, name: "web"),
        Workspace(index: 2, name: "ssh"),
        Workspace(index: 3, name: "files"),
    ]

    private(set) var activeIndex = 0

    /// Sin dock ni barra superior: los paneles se llevan la pantalla entera.
    var isFullScreen = false {
        didSet { if isFullScreen != oldValue { notifyChange() } }
    }

    var active: Workspace { workspaces[activeIndex] }

    /// Cambia de espacio. `number` es 1, 2 o 3, como en los atajos Cmd+1/2/3.
    func activate(number: Int) {
        let index = number - 1
        guard workspaces.indices.contains(index), index != activeIndex else { return }
        activeIndex = index
        notifyChange()
    }

    func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
