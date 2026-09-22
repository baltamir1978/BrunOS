import UIKit

/// Raíz de la pantalla externa: barra superior, mosaico y cursor.
///
/// **Todo lo de aquí se maqueta en puntos lógicos**, no en los puntos de UIKit
/// de la pantalla. La vista de contenido se escala con un `transform` para que
/// un espacio lógico de, por ejemplo, 1920×1080 ocupe los 3840×2160 píxeles
/// reales del monitor: el texto se dibuja entonces a resolución nativa, nítido,
/// en vez de rasterizarse pequeño y estirarse.
@MainActor
final class DesktopViewController: UIViewController {

    private let services = AppServices.shared
    private let topBar = TopBar()
    private let dock = Dock()
    /// Capa del fondo, detrás de todo.
    private let wallpaperLayer = CALayer()
    /// Lienzo en coordenadas lógicas. Todo lo demás cuelga de aquí.
    private let canvas = UIView()
    private let emptyLabel = UILabel()

    /// Tamaño del escritorio en puntos lógicos, incluida la barra.
    private var logicalSize: CGSize = .zero

    /// Divisor que se está arrastrando ahora mismo, si lo hay.
    private var activeDivider: (pane: PaneID, axis: LayoutContainer.Axis)?

    // MARK: - Ciclo de vida

    override func viewDidLoad() {
        super.viewDidLoad()

        // El escritorio va siempre oscuro, siga el iPhone el modo que siga.
        overrideUserInterfaceStyle = .dark

        view.backgroundColor = Tokens.Color.background
        canvas.backgroundColor = .clear
        canvas.layer.addSublayer(wallpaperLayer)
        view.addSubview(canvas)

        canvas.addSubview(topBar)
        canvas.addSubview(dock)

        dock.onSettings = { [weak self] in
            self?.presentSettings()
        }

        emptyLabel.attributedText = TopBar.brandText(size: 44)
        emptyLabel.textAlignment = .center
        canvas.addSubview(emptyLabel)

        services.desktopViewController = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshLayout),
            name: ExternalDisplayManager.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshLayout),
            name: DesktopModel.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshLayout),
            name: WallpaperStore.didChangeNotification,
            object: nil
        )
        // Una máquina recién añadida tiene que poder usarse sin reiniciar.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hostsChanged),
            name: HostStore.didChangeNotification,
            object: nil
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyDisplayProfile()
    }

    // MARK: - Espacio lógico

    /// Recoloca el lienzo según la escala y el overscan del perfil actual.
    ///
    /// Se llama cada vez que cambia algo de la pantalla: al conectar, al cambiar
    /// de resolución en caliente, al tocar la escala y al pasar por AirPlay.
    private func applyDisplayProfile() {
        guard let screen = view.window?.windowScene?.screen else { return }

        let profile = services.externalDisplay.currentProfile
            ?? DisplayProfileStore().profile(forNativePixels: ExternalDisplayManager.pixelSize(of: screen))

        // Puntos de UIKit que ocupa de verdad la ventana en el monitor.
        let physical = view.bounds.size
        guard physical.width > 0, physical.height > 0 else { return }

        let pixels = ExternalDisplayManager.pixelSize(of: screen)
        // Cuántos puntos lógicos caben a lo ancho: los píxeles reales partidos
        // por la escala elegida. De ahí sale el factor con el que se estira.
        let logicalWidth = pixels.width / profile.scale.rawValue
        let factor = physical.width / logicalWidth

        let inset = profile.overscan.rawValue
        let full = CGSize(width: logicalWidth, height: pixels.height / profile.scale.rawValue)
        logicalSize = CGSize(
            width: full.width * (1 - 2 * inset),
            height: full.height * (1 - 2 * inset)
        )

        canvas.transform = .identity
        canvas.bounds = CGRect(origin: .zero, size: logicalSize)
        canvas.transform = CGAffineTransform(scaleX: factor, y: factor)
        canvas.center = CGPoint(x: physical.width / 2, y: physical.height / 2)

        // **Esto es lo que hace que se vea nítido.**
        //
        // Una vista con `transform` escalado rasteriza su contenido al tamaño
        // nominal de sus bounds y **después** estira el mapa de bits. Con un
        // factor de 1,5 el texto sale emborronado, que es justo lo contrario de
        // lo que se pretende con las resoluciones escaladas.
        //
        // Subiendo `contentsScale` se le dice a Core Animation que dibuje a esa
        // densidad, así que el texto se rasteriza ya a resolución nativa y el
        // escalado no le quita un píxel de definición.
        contentsScale = screen.scale * max(factor, 1)

        layoutCanvas()
    }

    /// Densidad a la que se rasteriza el lienzo. Se propaga a mano porque
    /// `contentsScale` no se hereda: cada capa nueva nace con la de la pantalla.
    private var contentsScale: CGFloat = 1 {
        didSet {
            guard contentsScale != oldValue else { return }
            Log.desktop.info("contentsScale del lienzo: \(self.contentsScale, format: .fixed(precision: 2))")
        }
    }

    private func applyContentsScale(to view: UIView) {
        view.layer.contentsScale = contentsScale
        view.layer.rasterizationScale = contentsScale
        for layer in view.layer.sublayers ?? [] {
            applyContentsScale(to: layer)
        }
        for subview in view.subviews {
            applyContentsScale(to: subview)
        }
    }

    private func applyContentsScale(to layer: CALayer) {
        layer.contentsScale = contentsScale
        for sublayer in layer.sublayers ?? [] {
            applyContentsScale(to: sublayer)
        }
    }

    /// Evita que una maquetación dispare otra.
    ///
    /// Varias cosas de dentro avisan de que han cambiado —el dock, el fondo, el
    /// foco— y esos avisos vuelven aquí. Sin este cerrojo, un aviso mal puesto
    /// se convierte en recursión infinita y la app se cierra sin más.
    private var isLayingOut = false

    private func layoutCanvas() {
        guard !isLayingOut else { return }
        isLayingOut = true
        defer { isLayingOut = false }

        topBar.frame = CGRect(
            x: 0, y: 0,
            width: logicalSize.width,
            height: Tokens.Metric.topBarHeight
        )
        emptyLabel.frame = CGRect(
            x: 0, y: 0,
            width: logicalSize.width,
            height: logicalSize.height
        )

        settingsWindow?.frame = CGRect(origin: .zero, size: logicalSize)
        hostEditor?.frame = CGRect(origin: .zero, size: logicalSize)
        launcher?.frame = CGRect(origin: .zero, size: logicalSize)

        dock.frame = CGRect(
            x: 0,
            y: logicalSize.height - Dock.height - Dock.bottomMargin,
            width: logicalSize.width,
            height: Dock.height
        )
        dock.update(desktop: services.desktop)

        // El fondo va sin animación: si no, al cambiar de escala se ve la
        // imagen deslizándose hasta su sitio.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaperLayer.frame = CGRect(origin: .zero, size: logicalSize)
        services.wallpaper.apply(to: wallpaperLayer, size: logicalSize)
        CATransaction.commit()

        let workspace = services.desktop.active
        let gap = Tokens.Metric.tileGap
        let area = tileArea

        // El cursor se mueve por todo el escritorio, barra incluida.
        services.pointer.bounds = CGRect(origin: .zero, size: logicalSize)

        let frames = workspace.layout.frames(in: area, gap: gap)
        emptyLabel.isHidden = !frames.isEmpty

        // Los paneles de otros espacios se quedan fuera de la jerarquía: así no
        // consumen nada mientras no se vean, pero conservan su estado.
        for (id, pane) in workspace.panes {
            guard let frame = frames[id] else {
                pane.view.removeFromSuperview()
                continue
            }
            if pane.view.superview !== canvas {
                canvas.addSubview(pane.view)
            }
            pane.view.frame = frame
        }
        for other in services.desktop.workspaces where other !== workspace {
            for (_, pane) in other.panes where pane.view.superview === canvas {
                pane.view.removeFromSuperview()
            }
        }

        topBar.update(
            desktop: services.desktop,
            profile: services.externalDisplay.currentProfile,
            blockedCount: nil
        )

        // Los paneles y las etiquetas que acaban de aparecer nacen con la
        // densidad de la pantalla, no con la del lienzo.
        applyContentsScale(to: canvas)
    }

    @objc private func refreshLayout() {
        applyDisplayProfile()
    }

    /// Se añadió o cambió una máquina en el iPhone.
    ///
    /// Si algún panel de terminal está esperando —se creó cuando todavía no
    /// había ninguna configurada— se conecta ahora. Antes había que cerrar la
    /// app y volver a abrirla, porque el panel se quedaba con el aviso puesto
    /// para siempre.
    @objc private func hostsChanged() {
        guard let host = services.hosts.hosts.first else { return }
        for workspace in services.desktop.workspaces {
            for (_, pane) in workspace.panes {
                guard let terminal = pane as? TerminalPane, terminal.isWaitingForHost else { continue }
                terminal.openSession(to: host)
            }
        }
        services.desktop.notifyChange()
    }

    // MARK: - Órdenes del gestor de ventanas

    /// Ejecuta una orden ya resuelta por el `KeyboardRouter`.
    /// Devuelve `false` si no le corresponde y debería ir al panel.
    @discardableResult
    func perform(_ command: DesktopCommand) -> Bool {
        let workspace = services.desktop.active

        switch command {
        case .switchWorkspace(let number):
            services.desktop.activate(number: number)

        case .moveFocus(let direction):
            guard let focused = workspace.focused else { return true }
            let frames = currentFrames()
            if let next = workspace.layout.pane(from: focused, direction: direction, frames: frames) {
                workspace.setFocus(next)
            }

        case .movePane(let direction):
            guard let focused = workspace.focused else { return true }
            let frames = currentFrames()
            if let target = workspace.layout.pane(from: focused, direction: direction, frames: frames) {
                workspace.layout.swap(focused, target)
            }

        case .toggleMaximize:
            workspace.toggleMaximize()

        case .newPane:
            let kind = (workspace.focusedPane as? PlaceholderPane)?.kind
                ?? PaneKind.allCases.first { $0.preferredWorkspace == workspace.index }
                ?? .terminal
            addPane(kind: kind)

        case .newTab:
            switch workspace.focusedPane {
            case let terminal as TerminalPane: openTerminalSession(in: terminal)
            case let browser as BrowserPane: browser.newTab()
            default: return false
            }

        case .closeTab:
            switch workspace.focusedPane {
            case let terminal as TerminalPane: terminal.closeActiveTab()
            case let browser as BrowserPane: browser.closeActiveTab()
            default: return false
            }

        case .copy:
            switch workspace.focusedPane {
            case let terminal as TerminalPane: terminal.copySelection()
            case let browser as BrowserPane: browser.copySelection()
            default: return false
            }

        case .paste:
            switch workspace.focusedPane {
            case let terminal as TerminalPane: terminal.paste()
            case let browser as BrowserPane: browser.paste()
            default: return false
            }

        case .launcher:
            presentLauncher()

        case .addressBar:
            guard let browser = workspace.focusedPane as? BrowserPane else { return false }
            browser.focusAddressBar()

        case .reload:
            guard let browser = workspace.focusedPane as? BrowserPane else { return false }
            browser.reload()

        case .zoomIn, .zoomOut, .zoomReset:
            switch workspace.focusedPane {
            case let terminal as TerminalPane:
                switch command {
                case .zoomIn: terminal.changeFontSize(by: 1)
                case .zoomOut: terminal.changeFontSize(by: -1)
                default: terminal.resetFontSize()
                }
            case let browser as BrowserPane:
                switch command {
                case .zoomIn: browser.changeZoom(by: 0.1)
                case .zoomOut: browser.changeZoom(by: -0.1)
                default: browser.resetZoom()
                }
            default: return false
            }

        // Buscar en la página llega cuando haya barra de búsqueda.
        case .find:
            Log.desktop.debug("Orden aún sin destino: \(String(describing: command))")
            return false
        }

        services.desktop.notifyChange()
        return true
    }

    /// Pone en cada espacio de trabajo el panel que le da nombre.
    ///
    /// Antes sólo se creaba uno en el espacio activo, y al pulsar Cmd+2 o Cmd+3
    /// aparecía un escritorio vacío: indistinguible de que el cambio de espacio
    /// no funcionara.
    func populateEmptyWorkspaces() {
        let previous = services.desktop.activeIndex + 1
        for kind in PaneKind.allCases {
            services.desktop.activate(number: kind.preferredWorkspace)
            if services.desktop.active.isEmpty {
                addPane(kind: kind)
            }
        }
        services.desktop.activate(number: previous)
    }

    /// Crea un panel en el espacio activo.
    ///
    /// El terminal ya es real; el navegador y los ficheros siguen siendo el
    /// andamio de la Fase 1 hasta que les toque su fase.
    func addPane(kind: PaneKind, autoStart: Bool = true) {
        let workspace = services.desktop.active
        let id = PaneID()
        let focusedFrame = workspace.focused.flatMap { currentFrames()[$0] }

        let pane: any Pane = switch kind {
        case .terminal: TerminalPane(frame: .zero)
        case .browser: BrowserPane(frame: .zero)
        case .files: PlaceholderPane(kind: kind)
        }

        workspace.add(pane, id: id, focusedFrame: focusedFrame)
        services.desktop.notifyChange()

        if let terminal = pane as? TerminalPane {
            // `autoStart` en false cuando el host ya lo eligió el lanzador: si
            // no, abriría otro lanzador encima y, con varias máquinas, el ciclo
            // no terminaba nunca.
            if autoStart { openTerminalSession(in: terminal) }
        } else if let browser = pane as? BrowserPane {
            browser.newTab()
        }
    }

    /// Abre una sesión en un panel de terminal.
    ///
    /// Con un solo host se conecta directamente, que es el caso normal. Con
    /// varios abre el lanzador para elegir, en vez de decidir por su cuenta.
    func openTerminalSession(in pane: TerminalPane) {
        let hosts = services.hosts.hosts
        guard !hosts.isEmpty else {
            pane.showMessage("No hay ninguna máquina configurada.\n"
                             + "Añádela en el iPhone: Ajustes › SSH › Hosts.")
            return
        }
        if hosts.count == 1 {
            pane.openSession(to: hosts[0])
        } else {
            presentLauncher()
        }
    }

    // MARK: - Lanzador

    private var launcher: Launcher?
    private var settingsWindow: SettingsWindow?

    /// Ajustes, en el monitor.
    ///
    /// Tienen que estar aquí porque el iPhone, con pantalla externa, es sólo
    /// superficie táctil: si allí hubiera controles, el clic izquierdo acabaría
    /// pulsándolos en vez de llegar al escritorio.
    func presentSettings() {
        guard settingsWindow == nil else { return }
        let window = SettingsWindow(frame: CGRect(origin: .zero, size: logicalSize))
        window.onDismiss = { [weak self] in
            self?.settingsWindow?.removeFromSuperview()
            self?.settingsWindow = nil
        }
        window.onEditHost = { [weak self] host in
            self?.presentHostEditor(for: host)
        }
        canvas.addSubview(window)
        settingsWindow = window
    }

    private var hostEditor: HostEditorWindow?

    /// Alta y edición de máquinas, también en el monitor.
    ///
    /// Antes vivían en el iPhone, pero el teléfono se apaga con pantalla
    /// externa: teclear allí obliga a dejar de mirar el monitor.
    func presentHostEditor(for host: SSHHost?) {
        hostEditor?.removeFromSuperview()

        let editor = HostEditorWindow(
            host: host,
            frame: CGRect(origin: .zero, size: logicalSize)
        )
        editor.onDismiss = { [weak self] in
            self?.hostEditor?.removeFromSuperview()
            self?.hostEditor = nil
            self?.settingsWindow?.refresh()
        }
        canvas.addSubview(editor)
        hostEditor = editor
    }

    /// Conecta el terminal con foco a una máquina. Lo usan los ajustes.
    func connectTerminal(to host: SSHHost) {
        connectFocusedTerminal(to: host)
    }

    /// Cmd+P: elegir a qué máquina conectarse.
    ///
    /// En la Fase 3 y la 4 se le añadirán URLs y ubicaciones; de momento son
    /// los hosts, que es lo que hay.
    func presentLauncher() {
        launcher?.removeFromSuperview()

        let entries = services.hosts.hosts.map { host in
            Launcher.Entry(
                title: host.displayName,
                subtitle: "\(host.username)@\(host.host) · \(host.authentication.label)"
            ) { [weak self] in
                self?.connectFocusedTerminal(to: host)
            }
        }
        guard !entries.isEmpty else { return }

        let launcher = Launcher(entries: entries)
        launcher.onDismiss = { [weak self] in
            self?.launcher?.removeFromSuperview()
            self?.launcher = nil
        }
        canvas.addSubview(launcher)
        launcher.frame = CGRect(origin: .zero, size: logicalSize)
        self.launcher = launcher
    }

    private func connectFocusedTerminal(to host: SSHHost) {
        let workspace = services.desktop.active
        if let terminal = workspace.focusedPane as? TerminalPane {
            terminal.openSession(to: host)
        } else {
            addPane(kind: .terminal, autoStart: false)
            if let terminal = services.desktop.active.focusedPane as? TerminalPane {
                terminal.openSession(to: host)
            }
        }
    }

    /// El lanzador se lleva el teclado mientras está abierto.
    func launcherHandlesKey(_ event: KeyEvent) -> Bool {
        guard let launcher else { return false }
        return launcher.handleKey(event)
    }

    private func currentFrames() -> [PaneID: CGRect] {
        services.desktop.active.layout.frames(in: tileArea, gap: Tokens.Metric.tileGap)
    }

    /// Dónde se reparten los paneles: entre la barra y el dock.
    private var tileArea: CGRect {
        let gap = Tokens.Metric.tileGap
        let top = Tokens.Metric.topBarHeight + gap
        let bottom = Dock.height + Dock.bottomMargin + gap
        return CGRect(
            x: gap,
            y: top,
            width: max(0, logicalSize.width - 2 * gap),
            height: max(0, logicalSize.height - top - bottom)
        )
    }

    // MARK: - Puntero

    /// Instala el cursor dentro del lienzo y lo centra.
    func attachPointer() {
        services.pointer.attach(to: canvas, scene: view.window?.windowScene)
        services.pointer.center()
    }

    /// Entrega un clic o un scroll al panel que esté bajo el cursor.
    ///
    /// Antes de mirar los paneles se mira si el cursor está sobre un divisor:
    /// los huecos entre paneles no pertenecen a nadie y son la zona de arrastre
    /// para redimensionar.
    func deliverPointer(_ kind: PointerEvent.Kind, modifiers: UIKeyModifierFlags) {
        let position = services.pointer.position
        let frames = currentFrames()

        // Lo modal manda, y el editor va por encima de los ajustes.
        if let hostEditor, hostEditor.handlePointer(kind, at: position) { return }
        if let settingsWindow, settingsWindow.handlePointer(kind, at: position) { return }
        if let launcher, launcher.handlePointer(kind, at: position) { return }

        if handleDock(kind, at: position) { return }
        if handleTopBar(kind, at: position) { return }
        if handleDivider(kind, at: position, frames: frames) { return }

        guard let hit = frames.first(where: { $0.value.contains(position) }) else { return }

        let workspace = services.desktop.active
        if case .down = kind, workspace.focused != hit.key {
            workspace.setFocus(hit.key)
            services.desktop.notifyChange()
        }

        workspace.pane(hit.key)?.handlePointer(PointerEvent(
            kind: kind,
            location: CGPoint(
                x: position.x - hit.value.minX,
                y: position.y - hit.value.minY
            ),
            modifiers: modifiers
        ))
    }

    /// Clics en el dock. Devuelve `true` si consumió el evento.
    private func handleDock(_ kind: PointerEvent.Kind, at position: CGPoint) -> Bool {
        let pointInDock = CGPoint(x: position.x - dock.frame.minX, y: position.y - dock.frame.minY)
        guard dock.frame.contains(position), dock.contains(point: pointInDock) else { return false }
        guard case .down = kind else { return true }

        if dock.hitsSettings(pointInDock) {
            dock.onSettings?()
        } else if let number = dock.workspaceNumber(at: pointInDock) {
            services.desktop.activate(number: number)
        }
        return true
    }

    /// Clics en la barra superior. Devuelve `true` si consumió el evento.
    private func handleTopBar(_ kind: PointerEvent.Kind, at position: CGPoint) -> Bool {
        guard topBar.frame.contains(position) else { return false }
        guard case .down = kind else {
            // El resto de eventos sobre la barra se traga igualmente: no tiene
            // sentido que un clic empiece arriba y acabe en un panel.
            return true
        }

        let pointInBar = CGPoint(x: position.x - topBar.frame.minX, y: position.y - topBar.frame.minY)
        switch topBar.hit(at: pointInBar) {
        case .brand:
            presentLauncher()
        case .display:
            NotificationCenter.default.post(name: .brunosShowSettings, object: nil)
        case .none:
            break
        }
        return true
    }

    // MARK: - Divisores

    /// Gestiona el arrastre de un divisor. Devuelve `true` si consumió el evento.
    ///
    /// El reparto se guarda en fracciones, así que el desplazamiento en puntos
    /// se convierte a fracción del contenedor antes de aplicarlo. De ahí que
    /// arrastrar un divisor en un 4K a escala 2× mueva lo mismo, en proporción,
    /// que en un 1080p.
    private func handleDivider(
        _ kind: PointerEvent.Kind,
        at position: CGPoint,
        frames: [PaneID: CGRect]
    ) -> Bool {
        switch kind {
        case .down:
            guard let divider = divider(at: position, frames: frames) else { return false }
            activeDivider = divider
            return true

        case .moved:
            guard let divider = activeDivider, let frame = frames[divider.pane] else { return false }
            // Cuánto se ha alejado el cursor del borde del panel que se arrastra.
            let delta: CGFloat = divider.axis == .horizontal
                ? (position.x - frame.maxX) / max(1, logicalSize.width)
                : (position.y - frame.maxY) / max(1, logicalSize.height)
            guard abs(delta) > 0.0005 else { return true }
            services.desktop.active.layout.resize(
                pane: divider.pane,
                axis: divider.axis,
                delta: Double(delta)
            )
            layoutCanvas()
            return true

        case .up:
            guard activeDivider != nil else { return false }
            activeDivider = nil
            return true

        case .scroll:
            return false
        }
    }

    /// Busca si el cursor está en el hueco justo a la derecha o debajo de un
    /// panel, que es donde vive su divisor.
    private func divider(
        at position: CGPoint,
        frames: [PaneID: CGRect]
    ) -> (pane: PaneID, axis: LayoutContainer.Axis)? {
        // Un poco más ancho que el hueco: acertar con un hueco de 8 pt a pulso
        // con el ratón es incómodo.
        let reach = Tokens.Metric.tileGap

        for (id, frame) in frames {
            let vertical = position.x > frame.maxX
                && position.x < frame.maxX + reach
                && position.y >= frame.minY
                && position.y <= frame.maxY
            if vertical { return (id, .horizontal) }

            let horizontal = position.y > frame.maxY
                && position.y < frame.maxY + reach
                && position.x >= frame.minX
                && position.x <= frame.maxX
            if horizontal { return (id, .vertical) }
        }
        return nil
    }

    /// Entrega una tecla al panel con foco.
    func deliverKey(_ event: KeyEvent) {
        if let hostEditor, hostEditor.handleKey(event) { return }
        if let settingsWindow, settingsWindow.handleKey(event) { return }
        if launcherHandlesKey(event) { return }
        services.desktop.active.focusedPane?.handleKey(event)
    }

    /// Entrega texto de golpe al panel con foco: dictado o pegar.
    func insertText(_ text: String) {
        services.desktop.active.focusedPane?.insertText(text)
    }
}
