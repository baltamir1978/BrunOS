import UIKit

/// Los ajustes como una ventana más del escritorio: se mueven, se encajan,
/// se redimensionan y pueden quedar detrás de otras.
///
/// Antes eran una ventana modal (`SettingsWindow` a pantalla entera, con velo)
/// que tapaba todo y no dejaba tocar nada más. Bruno pidió que se comportara
/// como las demás (24-sep-2026). El contenido sigue siendo el mismo
/// `SettingsWindow`, en su modo `embedded`.
///
/// **No es una app del dock**: `PaneKind.of` devuelve `nil`, no se recuerda
/// al arrancar y el amarillo la cierra, porque minimizada no habría icono
/// desde el que volver a ella. Hay una sola a la vez: pedir otros ajustes
/// cambia lo que enseña.
@MainActor
final class SettingsPane: UIView, Pane {

    private(set) var scope: SettingsScope
    private var content: SettingsWindow
    private(set) var title: String

    var view: UIView { self }

    init(scope: SettingsScope, page: Int) {
        self.scope = scope
        let (window, title) = Self.makeContent(scope: scope, page: page)
        self.content = window
        self.title = title
        super.init(frame: .zero)

        backgroundColor = Tokens.Color.background
        layer.cornerRadius = Tokens.Metric.paneCornerRadius
        layer.borderWidth = Tokens.Metric.focusBorderWidth
        clipsToBounds = true
        install(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    private static func makeContent(scope: SettingsScope, page: Int) -> (SettingsWindow, String) {
        let pages = SettingsPages.window(for: scope)
        let window = SettingsWindow(
            title: pages.title,
            symbol: pages.symbol,
            pages: pages.pages,
            page: page,
            embedded: true,
            frame: .zero
        )
        return (window, pages.title)
    }

    private func install(_ window: SettingsWindow) {
        window.onDismiss = { [weak self] in
            guard let self else { return }
            AppServices.shared.desktopViewController?.closePane(self)
        }
        addSubview(window)
        setNeedsLayout()
    }

    /// Otros ajustes en la misma ventana: la rueda del navegador con los del
    /// terminal abiertos no abre una segunda.
    func show(scope: SettingsScope, page: Int) {
        guard scope != self.scope || page != 0 else { return }
        self.scope = scope
        content.removeFromSuperview()
        let (window, title) = Self.makeContent(scope: scope, page: page)
        content = window
        self.title = title
        install(window)
        AppServices.shared.desktop.notifyTitleChange()
    }

    func refresh() {
        content.refresh()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = bounds
    }

    // MARK: - Pane

    func setFocused(_ focused: Bool) {
        layer.borderColor = focused
            ? Tokens.Color.accent.desktopCGColor
            : Tokens.Color.border.desktopCGColor
    }

    func handlePointer(_ event: PointerEvent) {
        let x = SettingsWindow.controlsX
        let midY = SettingsWindow.controlsMidY
        content.hoveringControls = WindowControls.groupContains(event.location, x: x, midY: midY)
        if case .down(let button) = event.kind, button == .left,
           let control = WindowControls.button(at: event.location, x: x, midY: midY) {
            // Minimizada no tendría icono en el dock desde el que volver: el
            // amarillo también la cierra.
            WindowControls.perform(control == .minimize ? .close : control, on: self)
            return
        }
        _ = content.handlePointer(event.kind, at: event.location)
    }

    func handleKey(_ event: KeyEvent) {
        _ = content.handleKey(event)
    }

    func isDragArea(_ point: CGPoint) -> Bool {
        if WindowControls.button(at: point, x: SettingsWindow.controlsX, midY: SettingsWindow.controlsMidY) != nil {
            return false
        }
        return content.isTitleArea(point)
    }
}
