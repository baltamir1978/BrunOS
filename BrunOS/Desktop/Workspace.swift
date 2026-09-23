import CoreGraphics
import UIKit

/// Un espacio de trabajo: su mosaico, sus paneles y cuál tiene el foco.
///
/// BrunOS tiene tres, **sin vocación**: son los escritorios de macOS, y en
/// cualquiera caben ventanas de las tres apps a la vez. Antes cada app vivía en
/// el suyo (`1 web`, `2 ssh`, `3 files`) y el dock cambiaba de espacio al
/// pulsarla, así que abrir el terminal escondía el navegador y nunca se podían
/// ver dos apps juntas (23-sep-2026).
@MainActor
final class Workspace {

    let index: Int

    var layout = TilingLayout()
    private(set) var panes: [PaneID: any Pane] = [:]
    var focused: PaneID?

    /// Paneles mandados al dock con el botón amarillo, en el orden en que se
    /// minimizaron. Siguen vivos —la sesión SSH, la página—, sólo que fuera
    /// del mosaico.
    private(set) var minimized: [(id: PaneID, pane: any Pane, frame: CGRect?)] = []

    /// Ventanas flotantes: dónde está cada una, en puntos lógicos.
    ///
    /// Un panel está **o en el mosaico o flotando**, nunca en los dos: al
    /// flotar sale de `layout`, y al volver entra junto al que tenga el foco.
    private(set) var floating: [PaneID: CGRect] = [:]
    /// Orden de apilamiento, de la de más atrás a la de más delante.
    private(set) var floatingOrder: [PaneID] = []

    func isFloating(_ id: PaneID) -> Bool {
        floating[id] != nil
    }

    /// Saca un panel del mosaico y lo deja flotando en `frame`.
    func float(_ id: PaneID, frame: CGRect) {
        guard panes[id] != nil, floating[id] == nil else { return }
        if layout.maximized == id { layout.maximized = nil }
        layout.remove(id)
        floating[id] = frame
        floatingOrder.append(id)
    }

    /// Devuelve una ventana flotante al mosaico, junto al panel `neighbor`.
    func tile(_ id: PaneID, nextTo neighbor: PaneID?, neighborFrame: CGRect?) {
        guard floating[id] != nil else { return }
        floating[id] = nil
        floatingOrder.removeAll { $0 == id }
        layout.insert(id, nextTo: neighbor, focusedFrame: neighborFrame)
    }

    func setFloatingFrame(_ id: PaneID, _ frame: CGRect) {
        guard floating[id] != nil else { return }
        floating[id] = frame
    }

    /// Pone una ventana flotante delante de todas.
    func raise(_ id: PaneID) {
        guard floating[id] != nil, floatingOrder.last != id else { return }
        floatingOrder.removeAll { $0 == id }
        floatingOrder.append(id)
    }

    /// Añade un panel directamente flotando, sin pasar por el mosaico.
    func addFloating(_ pane: any Pane, id: PaneID, frame: CGRect) {
        panes[id] = pane
        floating[id] = frame
        floatingOrder.append(id)
        setFocus(id)
    }

    init(index: Int) {
        self.index = index
    }

    var isEmpty: Bool { panes.isEmpty }

    var focusedPane: (any Pane)? {
        guard let focused else { return nil }
        return panes[focused]
    }

    func pane(_ id: PaneID) -> (any Pane)? {
        panes[id]
    }

    /// Las ventanas de una app, de la de más delante a la de más atrás: la
    /// que tiene el foco, luego las flotantes por apilamiento y al final las
    /// del mosaico.
    func panes(of kind: PaneKind) -> [PaneID] {
        let order = [focused].compactMap { $0 } + floatingOrder.reversed() + layout.panes
        var seen = Set<PaneID>()
        return order.filter { id in
            guard let pane = panes[id], PaneKind.of(pane) == kind else { return false }
            return seen.insert(id).inserted
        }
    }

    /// Si la app tiene algo aquí, minimizado incluido.
    func hasAny(of kind: PaneKind) -> Bool {
        !panes(of: kind).isEmpty || minimized.contains { PaneKind.of($0.pane) == kind }
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
        floating[id] = nil
        floatingOrder.removeAll { $0 == id }
        if focused == id {
            focused = nil
            setFocus(floatingOrder.last ?? layout.panes.first)
        }
    }

    func setFocus(_ id: PaneID?) {
        if let previous = focused, let pane = panes[previous] {
            pane.setFocused(false)
        }
        focused = id
        if let id, let pane = panes[id] {
            pane.setFocused(true)
            // Como en macOS: la ventana que recibe el foco pasa delante.
            raise(id)
        }
    }

    /// Saca un panel del mosaico y lo deja en el dock.
    func minimize(_ id: PaneID) {
        guard let pane = panes[id] else { return }
        if layout.maximized == id { layout.maximized = nil }
        pane.setFocused(false)
        pane.view.removeFromSuperview()
        // Una ventana flotante vuelve flotando y donde estaba.
        let frame = floating[id]
        panes[id] = nil
        layout.remove(id)
        floating[id] = nil
        floatingOrder.removeAll { $0 == id }
        minimized.append((id, pane, frame))
        if focused == id {
            focused = nil
            setFocus(floatingOrder.last ?? layout.panes.first)
        }
    }

    /// Lo devuelve al mosaico, junto al panel con foco, y le da el foco.
    func restore(_ id: PaneID, focusedFrame: CGRect?) {
        guard let index = minimized.firstIndex(where: { $0.id == id }) else { return }
        let entry = minimized.remove(at: index)
        if let frame = entry.frame {
            addFloating(entry.pane, id: entry.id, frame: frame)
        } else {
            add(entry.pane, id: entry.id, focusedFrame: focusedFrame)
        }
    }

    /// Alterna el panel maximizado. Es el *fullscreen* de i3: ocupa todo el
    /// espacio del escritorio, no se convierte en ventana flotante.
    func toggleMaximize() {
        guard let focused else { return }
        layout.maximized = layout.maximized == focused ? nil : focused
    }
}

/// Preferencias del gestor de ventanas.
@MainActor
enum DesktopPreferences {
    /// Si los paneles nuevos salen como ventanas flotantes en vez de entrar
    /// en el mosaico. **Por defecto flotan**, como en macOS: Bruno quería ver
    /// unas ventanas encima de otras (23-sep-2026).
    static var newPanesFloat: Bool {
        get { UserDefaults.standard.object(forKey: "desktop.newPanesFloat") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "desktop.newPanesFloat") }
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

    let workspaces: [Workspace] = (1...3).map { Workspace(index: $0) }

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
