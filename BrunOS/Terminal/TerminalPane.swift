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
    private var tabs: [TerminalTab] = []
    private var activeIndex = 0

    var title: String {
        guard let tab = activeTab else { return "Terminal" }
        return tab.title
    }

    var view: UIView { self }

    private var activeTab: TerminalTab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = Tokens.Color.terminalBackground
        layer.cornerRadius = Tokens.Metric.paneCornerRadius
        layer.borderWidth = Tokens.Metric.focusBorderWidth
        layer.borderColor = Tokens.Color.border.cgColor
        clipsToBounds = true

        addSubview(tabBar)
        addSubview(content)

        tabBar.onSelect = { [weak self] index in
            self?.activate(index)
        }
        tabBar.onClose = { [weak self] index in
            self?.closeTab(at: index)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    // MARK: - Maquetación

    override func layoutSubviews() {
        super.layoutSubviews()

        // La barra de pestañas se esconde cuando sólo hay una: en un panel que
        // suele tener una sola sesión, roba alto sin aportar nada.
        let barHeight: CGFloat = tabs.count > 1 ? 26 : 0
        tabBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        tabBar.isHidden = barHeight == 0
        content.frame = CGRect(
            x: 0,
            y: barHeight,
            width: bounds.width,
            height: max(0, bounds.height - barHeight)
        )
        for tab in tabs {
            tab.terminalView.frame = content.bounds
        }
    }

    // MARK: - Pestañas

    /// Abre una sesión contra un host y le pasa el foco.
    @discardableResult
    func openSession(to host: SSHHost) -> TerminalTab {
        let tab = TerminalTab(host: host)
        tab.onTitleChange = { [weak self] in
            self?.tabBar.update(titles: self?.tabs.map(\.title) ?? [], active: self?.activeIndex ?? 0)
            AppServices.shared.desktop.notifyChange()
        }
        tabs.append(tab)
        content.addSubview(tab.terminalView)
        activate(tabs.count - 1)
        setNeedsLayout()
        tab.connect()
        return tab
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs.remove(at: index)
        tab.disconnect()
        tab.terminalView.removeFromSuperview()
        activate(min(activeIndex, tabs.count - 1))
        setNeedsLayout()
        AppServices.shared.desktop.notifyChange()
    }

    /// Cierra la pestaña activa. Lo llama Cmd+W.
    func closeActiveTab() {
        closeTab(at: activeIndex)
    }

    private func activate(_ index: Int) {
        activeIndex = max(0, index)
        for (position, tab) in tabs.enumerated() {
            tab.terminalView.isHidden = position != activeIndex
        }
        tabBar.update(titles: tabs.map(\.title), active: activeIndex)
        AppServices.shared.desktop.notifyChange()
    }

    // MARK: - Pane

    func setFocused(_ focused: Bool) {
        layer.borderColor = focused
            ? Tokens.Color.accent.cgColor
            : Tokens.Color.border.cgColor
        // El cursor del terminal lo gobierna SwiftTerm por su cuenta; aquí
        // sólo se marca el panel.
    }

    func handleKey(_ event: KeyEvent) {
        guard event.phase == .down, let tab = activeTab else { return }
        tab.sendKey(event.key)
    }

    func insertText(_ text: String) {
        activeTab?.session.send(text)
    }

    func handlePointer(_ event: PointerEvent) {
        guard let tab = activeTab else { return }
        switch event.kind {
        case .scroll(let delta):
            tab.scroll(by: delta)
        case .down(let button) where button == .left:
            tab.beginSelection(at: pointInTerminal(event.location))
        case .moved:
            tab.extendSelection(to: pointInTerminal(event.location))
        case .up:
            tab.endSelection()
        default:
            break
        }
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

    /// Pega el portapapeles en la sesión. Cmd+V.
    func paste() {
        guard let text = UIPasteboard.general.string else { return }
        activeTab?.session.send(text)
    }
}
