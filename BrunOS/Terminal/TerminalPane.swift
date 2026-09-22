import SwiftTerm
import UIKit

/// Panel de terminal, con una pestaña por sesión SSH.
///
/// **El terminal no recibe eventos del sistema.** La pantalla externa no es
/// interactiva, así que todo —teclas, clics, rueda— entra por los métodos del
/// protocolo `Pane` y se reinyecta a mano en `TerminalView`.
@MainActor
final class TerminalPane: UIView, Pane {

    private let tabBar = TerminalTabBar()
    private let content = UIView()
    private let home = TerminalHomeView()
    private var tabs: [TerminalTab] = []
    private var activeIndex = 0
    /// Se está viendo la lista de conexiones en vez de una sesión.
    private(set) var isShowingHome = true

    var title: String {
        guard !isShowingHome, let tab = activeTab else { return "Terminal" }
        return tab.title
    }

    var view: UIView { self }

    private var activeTab: TerminalTab? {
        guard !isShowingHome else { return nil }
        return tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        layer.cornerRadius = Tokens.Metric.paneCornerRadius
        layer.borderWidth = Tokens.Metric.focusBorderWidth
        layer.borderColor = Tokens.Color.border.desktopCGColor
        clipsToBounds = true

        addSubview(tabBar)
        addSubview(content)
        content.addSubview(home)

        home.onConnect = { [weak self] host in
            self?.openSession(to: host)
        }

        applyTheme()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: TerminalTheme.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: DesktopTheme.didChangeNotification, object: nil
        )
        refreshBar()
    }

    // MARK: - Tema

    @objc private func themeChanged() {
        applyTheme()
    }

    /// El panel entero se pone en el modo del terminal, que puede no ser el
    /// del escritorio: así la barra, la lista de conexiones y el aviso de
    /// reconexión salen a juego con la consola.
    private func applyTheme() {
        let style = TerminalTheme.style
        overrideUserInterfaceStyle = style
        backgroundColor = TerminalTheme.background(for: style)
        for tab in tabs {
            tab.applyTheme(style)
        }
        tabBar.setNeedsDisplay()
        home.setNeedsDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    // MARK: - Maquetación

    override func layoutSubviews() {
        super.layoutSubviews()

        let barHeight = TerminalTabBar.height
        tabBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        content.frame = CGRect(
            x: 0,
            y: barHeight,
            width: bounds.width,
            height: max(0, bounds.height - barHeight)
        )
        home.frame = content.bounds
        for tab in tabs {
            tab.terminalView.frame = content.bounds
        }
    }

    private func refreshBar() {
        tabBar.update(
            titles: tabs.map(\.title),
            active: tabs.isEmpty ? nil : activeIndex,
            showsHome: isShowingHome
        )
    }

    // MARK: - Pestañas

    /// Abre una sesión contra un host y le pasa el foco.
    @discardableResult
    func openSession(to host: SSHHost) -> TerminalTab {
        let tab = TerminalTab(host: host)
        tab.onTitleChange = { [weak self] in
            self?.refreshBar()
            AppServices.shared.desktop.notifyChange()
        }
        // Al salir con `exit`, fuera la pestaña y de vuelta a la lista, para
        // elegir la misma máquina u otra.
        tab.onEnded = { [weak self, weak tab] in
            guard let self, let tab, let index = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.closeTab(at: index)
            self.showHome()
        }
        tab.applyTheme(TerminalTheme.style)
        tabs.append(tab)
        content.addSubview(tab.terminalView)
        activate(tabs.count - 1)
        setNeedsLayout()
        tab.connect()
        return tab
    }

    /// Cierra todas las sesiones. Lo usa el botón rojo, al cerrar el panel.
    func closeAll() {
        for tab in tabs {
            tab.disconnect()
            tab.terminalView.removeFromSuperview()
        }
        tabs.removeAll()
    }

    /// Enseña la lista de conexiones. Cmd+T y el «+» de la barra.
    func showHome() {
        isShowingHome = true
        home.reload()
        updateVisibility()
        refreshBar()
        AppServices.shared.desktop.notifyChange()
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs.remove(at: index)
        tab.disconnect()
        tab.terminalView.removeFromSuperview()
        if tabs.isEmpty {
            showHome()
        } else {
            activate(min(index, tabs.count - 1))
        }
        setNeedsLayout()
        AppServices.shared.desktop.notifyChange()
    }

    /// Cierra la pestaña activa. Lo llama Cmd+W. Con la lista de conexiones
    /// delante, la cierra y vuelve a la última sesión, si la hay.
    func closeActiveTab() {
        if isShowingHome {
            guard !tabs.isEmpty else { return }
            activate(activeIndex)
            return
        }
        closeTab(at: activeIndex)
    }

    private func activate(_ index: Int) {
        activeIndex = max(0, min(index, tabs.count - 1))
        isShowingHome = tabs.isEmpty
        updateVisibility()
        refreshBar()
        AppServices.shared.desktop.notifyChange()
    }

    private func updateVisibility() {
        home.isHidden = !isShowingHome
        for (position, tab) in tabs.enumerated() {
            tab.terminalView.isHidden = isShowingHome || position != activeIndex
        }
    }

    // MARK: - Pane

    func setFocused(_ focused: Bool) {
        layer.borderColor = focused
            ? Tokens.Color.accent.desktopCGColor
            : Tokens.Color.border.desktopCGColor
        // El cursor del terminal lo gobierna SwiftTerm por su cuenta; aquí
        // sólo se marca el panel.
    }

    func handleKey(_ event: KeyEvent) {
        if isShowingHome {
            home.handleKey(event)
            return
        }
        guard event.phase == .down, let tab = activeTab else { return }
        tab.sendKey(event.key)
    }

    func insertText(_ text: String) {
        activeTab?.session.send(text)
    }

    func handlePointer(_ event: PointerEvent) {
        if tabBar.frame.contains(event.location) {
            tabBar.hover(at: event.location)
            guard case .down(let button) = event.kind, button == .left else { return }
            switch tabBar.target(at: event.location) {
            case .tab(let index): activate(index)
            case .close(let index): closeTab(at: index)
            case .newTab: showHome()
            case .settings: AppServices.shared.desktopViewController?.presentSettings(.terminal)
            case .window(let button): WindowControls.perform(button, on: self)
            case nil: break
            }
            return
        }
        tabBar.hover(at: nil)

        if isShowingHome {
            home.handlePointer(PointerEvent(
                kind: event.kind,
                location: CGPoint(x: event.location.x, y: event.location.y - content.frame.minY),
                modifiers: event.modifiers
            ))
            return
        }
        guard let tab = activeTab else { return }

        tab.handlePointer(
            event.kind,
            at: pointInTerminal(event.location),
            modifiers: event.modifiers
        )
    }

    func isDragArea(_ point: CGPoint) -> Bool {
        tabBar.frame.contains(point) && tabBar.target(at: point) == nil
    }

    private func pointInTerminal(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y - tabBar.frame.height)
    }

    // MARK: - Zoom

    /// Cmd + / − / 0 cambian el cuerpo de la fuente del terminal.
    func changeFontSize(by delta: CGFloat) {
        for tab in tabs {
            tab.changeFontSize(by: delta)
        }
    }

    func resetFontSize() {
        for tab in tabs {
            tab.resetFontSize()
        }
    }

    /// Copia la selección al portapapeles. Cmd+C.
    func copySelection() {
        activeTab?.copySelection()
    }

    func clearSelection() {
        activeTab?.clearSelection()
    }

    /// Pega el portapapeles en la sesión. Cmd+V.
    func paste() {
        guard let text = UIPasteboard.general.string else { return }
        activeTab?.session.send(text)
    }
}
