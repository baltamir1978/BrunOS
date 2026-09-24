import UIKit
import WebKit

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

        // Claro u oscuro según `DesktopTheme`: por defecto, como el iPhone.
        overrideUserInterfaceStyle = DesktopTheme.style

        view.backgroundColor = Tokens.Color.background
        canvas.backgroundColor = .clear
        canvas.layer.addSublayer(wallpaperLayer)
        // Capa nueva (se ha vuelto a enchufar el monitor): hay que pintarla.
        services.wallpaper.invalidate()
        view.addSubview(canvas)

        canvas.addSubview(topBar)
        canvas.addSubview(dock)

        dock.onSettings = { [weak self] in
            self?.presentSettings(.global)
        }

        emptyLabel.attributedText = TopBar.brandText(size: 44)
        emptyLabel.textAlignment = .center
        canvas.addSubview(emptyLabel)

        services.desktopViewController = self
        services.weather.start()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshLayout),
            name: ExternalDisplayManager.didChangeNotification,
            object: nil
        )
        // Un cambio del escritorio (foco, una ventana nueva) no toca la
        // pantalla: basta con maquetar, sin volver a colocar el lienzo.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(desktopChanged),
            name: DesktopModel.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(titleChanged),
            name: DesktopModel.titleDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshLayout),
            name: WallpaperStore.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeChanged),
            name: DesktopTheme.didChangeNotification,
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
        //
        // **La densidad exacta, ni más ni menos** (24-sep-2026): píxeles del
        // monitor por punto lógico, que es la escala elegida. Antes era
        // `screen.scale * max(factor, 1)`: con un monitor que iOS ve como
        // Retina, a 1,5× se dibujaba a 2 píxeles por punto y la reducción a
        // 1,5 dejaba el texto un poco blando. Bruno lo seguía notando.
        contentsScale = screen.scale * factor
        if canvasFactor != factor {
            canvasFactor = factor
            // Las páginas deshacen este estirado por su cuenta: hay que
            // recolocarlas aunque su hueco no haya cambiado de tamaño.
            for pane in services.desktop.active.panes.values {
                pane.view.setNeedsLayout()
            }
            for entry in services.desktop.active.minimized {
                entry.pane.view.setNeedsLayout()
            }
        }

        layoutCanvas()
    }

    /// Cuánto estira el lienzo: puntos de UIKit por punto lógico. Lo necesita
    /// el navegador, que lo deshace (ver `BrowserTab.place`).
    private(set) var canvasFactor: CGFloat = 1

    /// Densidad a la que se rasteriza el lienzo. Se propaga a mano porque
    /// `contentsScale` no se hereda: cada capa nueva nace con la de la pantalla.
    private var contentsScale: CGFloat = 1 {
        didSet {
            guard contentsScale != oldValue else { return }
            Log.desktop.info("contentsScale del lienzo: \(self.contentsScale, format: .fixed(precision: 2))")
        }
    }

    /// **Si cambia la densidad, hay que volver a dibujar.** Subir
    /// `contentsScale` no repinta lo que ya estaba dibujado: una vista que se
    /// pintó antes de entrar en el lienzo se quedaba con su primer dibujado, a
    /// baja densidad, hasta que algo la obligara a repintarse. La barra del
    /// terminal, que casi nunca cambia, salía borrosa por eso.
    private func applyContentsScale(to view: UIView) {
        // Dentro de un `WKWebView` no hay nada nuestro: WebKit decide su
        // densidad (y la página ya va a 1:1, ver `BrowserTab.place`). Además,
        // su árbol de capas es enorme y esto se recorre en cada maquetación.
        guard !(view is WKWebView) else { return }
        // Las instantáneas de Exposé se encogen: con `.nearest` saldrían a
        // trozos. Ver `OverviewThumbnail`.
        guard !(view is OverviewThumbnail) else { return }
        if view.layer.contentsScale != contentsScale {
            view.layer.contentsScale = contentsScale
            view.setNeedsDisplay()
        }
        // Lo que se dibuja ya va a un píxel de pantalla por píxel dibujado, así
        // que no hace falta interpolar: con el filtro lineal, una vista que cae
        // entre dos píxeles (a 1,5× pasa con cualquier posición impar) se
        // emborronaba medio píxel. Las imágenes sí se escalan, y se quedan como
        // estaban.
        if !(view is UIImageView) {
            view.layer.magnificationFilter = .nearest
            view.layer.minificationFilter = .nearest
        }
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

    /// Un marco llevado a píxeles enteros del monitor. A 1,5×, un punto lógico
    /// son 1,5 píxeles: una ventana en x = 7 empezaba en el píxel 10,5 y todo
    /// su contenido se volvía a muestrear.
    private func pixelAligned(_ rect: CGRect) -> CGRect {
        let scale = max(contentsScale, 1)
        let minX = (rect.minX * scale).rounded() / scale
        let minY = (rect.minY * scale).rounded() / scale
        let maxX = (rect.maxX * scale).rounded() / scale
        let maxY = (rect.maxY * scale).rounded() / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
        PerformanceMonitor.shared.noteLayout()

        let fullScreen = services.desktop.isFullScreen
        topBar.frame = CGRect(
            x: 0, y: fullScreen && !topBarRevealed ? -Tokens.Metric.topBarHeight : 0,
            width: logicalSize.width,
            height: Tokens.Metric.topBarHeight
        )
        emptyLabel.frame = CGRect(
            x: 0, y: 0,
            width: logicalSize.width,
            height: logicalSize.height
        )

        hostEditor?.frame = CGRect(origin: .zero, size: logicalSize)
        quickLook?.frame = CGRect(origin: .zero, size: logicalSize)
        prompt?.frame = CGRect(origin: .zero, size: logicalSize)
        launcher?.frame = CGRect(origin: .zero, size: logicalSize)
        historyWindow?.frame = CGRect(origin: .zero, size: logicalSize)
        overview?.frame = CGRect(origin: .zero, size: logicalSize)
        weatherPopover?.frame = CGRect(origin: .zero, size: logicalSize)

        // Una ventana que ocupa el sitio del dock (una encajada llega hasta
        // abajo) lo esconde, como la pantalla completa: asoma al llevar el
        // cursor al borde de abajo. Bruno no quería el hueco (24-sep-2026).
        dockAutoHidden = fullScreen || dockIsCovered()
        if !dockAutoHidden { dockRevealed = false }
        let dockHidden = dockAutoHidden && !dockRevealed
        dock.frame = pixelAligned(CGRect(
            x: 0,
            y: logicalSize.height - (dockHidden ? -Dock.bottomMargin : Dock.height + Dock.bottomMargin),
            width: logicalSize.width,
            height: Dock.height
        ))

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

        let frames = paneFrames(tiled: workspace.layout.frames(in: area, gap: gap), in: workspace)
        emptyLabel.isHidden = !frames.isEmpty

        // Un panel sin marco (el maximizado tapa a los demás) sale de la
        // jerarquía: no consume nada mientras no se ve, pero conserva su estado.
        for (id, pane) in workspace.panes {
            guard let frame = frames[id] else {
                pane.view.removeFromSuperview()
                continue
            }
            if pane.view.superview !== canvas {
                canvas.addSubview(pane.view)
            }
            pane.view.frame = pixelAligned(frame)
        }
        arrangeFloating(in: workspace, frames: frames)

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

    @objc private func desktopChanged() {
        layoutCanvas()
        scheduleSessionSave()
    }

    @objc private func titleChanged() {
        // Cambiar de pestaña o de web también es algo que recordar.
        scheduleSessionSave()
        topBar.update(
            desktop: services.desktop,
            profile: services.externalDisplay.currentProfile,
            blockedCount: nil
        )
        // Lo que cambia de título a veces trae vistas nuevas (una pestaña de
        // terminal), que nacen con la densidad de la pantalla. Se les pone la
        // del lienzo una vez por vuelta, no con cada aviso.
        guard !contentsScalePending else { return }
        contentsScalePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.contentsScalePending = false
            self.applyContentsScale(to: self.canvas)
        }
    }

    private var contentsScalePending = false

    @objc private func themeChanged() {
        applyTheme()
    }

    /// Pasa el escritorio entero a claro o a oscuro, en caliente.
    ///
    /// Cambiar `overrideUserInterfaceStyle` basta para las etiquetas y los
    /// fondos de las vistas, que llevan colores dinámicos. **No basta para las
    /// capas**: un `CGColor` es un color ya resuelto y no se entera de nada, así
    /// que los bordes, el fondo y todo lo que se dibuja a mano hay que volver a
    /// pintarlo. Se incluyen los minimizados, que están fuera de la jerarquía y
    /// no reciben el cambio de rasgos.
    func applyTheme() {
        overrideUserInterfaceStyle = DesktopTheme.style

        redraw(canvas)
        let workspace = services.desktop.active
        for (id, pane) in workspace.panes {
            pane.setFocused(id == workspace.focused)
            if pane.view.superview == nil { redraw(pane.view) }
        }
        for entry in workspace.minimized {
            entry.pane.setFocused(false)
            redraw(entry.pane.view)
        }
        dock.applyTheme()
        UIView.refreshThemedBorders()
        services.wallpaper.invalidate()
        layoutCanvas()
    }

    private func redraw(_ view: UIView) {
        view.setNeedsDisplay()
        // Dentro de un `WKWebView` no hay nada nuestro, y la página ya se
        // entera sola del modo por `prefers-color-scheme`.
        guard !(view is WKWebView) else { return }
        for subview in view.subviews {
            redraw(subview)
        }
    }

    /// Se añadió o cambió una máquina. La lista de conexiones del terminal se
    /// entera sola; aquí sólo se repinta el resto.
    @objc private func hostsChanged() {
        services.desktop.notifyChange()
    }

    // MARK: - Órdenes del gestor de ventanas

    /// Un atajo que llega del teclado. Con una ventana modal delante no
    /// puede tocar lo de detrás: ver `performOverModal`.
    ///
    /// **La guardia va aquí y no en `perform`**: las propias ventanas llaman a
    /// `perform` estando abiertas (el interruptor de pantalla completa de
    /// Ajustes), y con la guardia dentro se quedaban sin efecto.
    func performShortcut(_ command: DesktopCommand) -> Bool {
        // El conmutador y Exposé mandan sobre sí mismos aunque estén delante.
        switch command {
        case .switchWindow, .endWindowSwitch:
            return perform(command)
        case .expose where overview != nil:
            return perform(command)
        default:
            break
        }
        return performOverModal(command) ?? perform(command)
    }

    /// Ejecuta una orden, venga del teclado o de un botón.
    /// Devuelve `false` si no le corresponde y debería ir al panel.
    @discardableResult
    func perform(_ command: DesktopCommand) -> Bool {
        let workspace = services.desktop.active

        switch command {
        case .openApp(let kind):
            openFromDock(kind)

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
            if let focused = workspace.focused, workspace.isFloating(focused) {
                toggleZoom(focused, fullScreen: false)
            } else {
                workspace.toggleMaximize()
            }

        case .toggleFullScreen:
            dockRevealed = false
            topBarRevealed = false
            let entering = !services.desktop.isFullScreen
            if entering, let focused = workspace.focused, workspace.isFloating(focused) {
                // Una flotante a pantalla completa se lleva la pantalla entera,
                // como una ventana de macOS con el botón verde.
                zoomRestore[focused] = nil
                toggleZoom(focused, fullScreen: true)
            } else if !entering {
                for (id, frame) in zoomRestore { workspace.setFloatingFrame(id, frame) }
                zoomRestore.removeAll()
            }
            services.desktop.isFullScreen = entering

        case .toggleFloating:
            guard let focused = workspace.focused else { return true }
            toggleFloating(focused)

        case .newPane:
            // Cmd+N: otra ventana de la app que está delante, como en macOS.
            addPane(kind: workspace.focusedPane.flatMap(PaneKind.of) ?? .terminal)

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
            case let files as FilesPane: files.copySelection()
            case let notes as NotesPane: notes.copySelection()
            default: return false
            }

        case .paste:
            switch workspace.focusedPane {
            case let terminal as TerminalPane: terminal.paste()
            case let browser as BrowserPane: browser.paste()
            case let files as FilesPane: files.pasteHere()
            case let notes as NotesPane: notes.paste()
            default: return false
            }

        case .launcher:
            presentLauncher()

        case .history:
            presentHistory()

        case .addressBar:
            guard let browser = workspace.focusedPane as? BrowserPane else { return false }
            browser.focusAddressBar()

        case .reopenTab:
            guard let browser = workspace.focusedPane as? BrowserPane else { return false }
            browser.reopenClosedTab()

        case .bookmark:
            guard let browser = workspace.focusedPane as? BrowserPane else { return false }
            browser.toggleBookmark()

        case .reader:
            guard let browser = workspace.focusedPane as? BrowserPane else { return false }
            browser.toggleReader()

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

        case .find:
            switch workspace.focusedPane {
            case let browser as BrowserPane: browser.showFind()
            case let terminal as TerminalPane: terminal.showFind()
            case let files as FilesPane: files.showFind()
            default: return false
            }

        case .switchWindow(let backwards):
            cycleWindows(backwards: backwards)
            return true

        case .endWindowSwitch:
            // Llega con cada Cmd que se suelta: sin conmutador, nada.
            endWindowSwitch()
            return true

        case .expose:
            toggleExpose()
            return true

        case .muteTab:
            guard let browser = workspace.focusedPane as? BrowserPane else { return false }
            browser.toggleMuteActiveTab()
        }

        services.desktop.notifyChange()
        return true
    }

    // MARK: - Recordar el escritorio

    /// Cómo está el escritorio ahora, para el próximo arranque.
    ///
    /// El orden importa: primero el mosaico, luego las flotantes de la de más
    /// atrás a la de más delante, y al final las minimizadas. Así, al
    /// recuperarlas una tras otra, cada una queda donde estaba.
    private func sessionSnapshot() -> SavedDesktop? {
        guard logicalSize.width > 0 else { return nil }
        let workspace = services.desktop.active

        func window(_ pane: any Pane, frame: CGRect?, minimized: Bool, focused: Bool) -> SavedDesktop.Window? {
            // Los ajustes no se recuerdan: no son una app.
            guard let kind = PaneKind.of(pane) else { return nil }
            var saved = SavedDesktop.Window(kind: kind.rawValue, frame: frame,
                                            isMinimized: minimized, isFocused: focused)
            switch pane {
            case let browser as BrowserPane:
                let session = browser.sessionTabs
                saved.tabs = session.urls
                saved.activeTab = session.active
                saved.pinnedTabs = session.pinned.contains(true) ? session.pinned : nil
            case let terminal as TerminalPane:
                let session = terminal.sessionHosts
                saved.hosts = session.ids
                saved.activeHost = session.active
            case let files as FilesPane:
                let session = files.sessionLocation
                saved.location = session.location
                saved.path = session.path
            default:
                break
            }
            return saved
        }

        var windows: [SavedDesktop.Window] = []
        for id in workspace.layout.panes {
            guard let pane = workspace.pane(id),
                  let saved = window(pane, frame: nil, minimized: false, focused: id == workspace.focused)
            else { continue }
            windows.append(saved)
        }
        for id in workspace.floatingOrder {
            guard let pane = workspace.pane(id) else { continue }
            // Una encajada o maximizada se guarda con su tamaño de antes.
            let frame = zoomRestore[id] ?? workspace.floating[id]
            guard let saved = window(pane, frame: frame, minimized: false, focused: id == workspace.focused)
            else { continue }
            windows.append(saved)
        }
        for entry in workspace.minimized {
            guard let saved = window(entry.pane, frame: entry.frame, minimized: true, focused: false) else { continue }
            windows.append(saved)
        }
        return SavedDesktop(windows: windows, logicalSize: logicalSize)
    }

    private func scheduleSessionSave() {
        SessionStore.scheduleSave { [weak self] in self?.sessionSnapshot() }
    }

    /// Al irse la app a segundo plano: iOS puede cerrarla ahí sin avisar.
    func saveSessionNow() {
        SessionStore.saveNow(sessionSnapshot())
    }

    /// Al conectar el monitor con el escritorio vacío: las ventanas de la
    /// última vez, si así está en Ajustes. Si no, se queda vacío hasta que se
    /// pulse el dock.
    func restoreSession() {
        guard DesktopPreferences.restoresSession, let saved = SessionStore.load() else { return }
        let workspace = services.desktop.active
        // Con otra escala u otro monitor, las ventanas se reparten en
        // proporción.
        let sx = saved.logicalSize.width > 0 ? logicalSize.width / saved.logicalSize.width : 1
        let sy = saved.logicalSize.height > 0 ? logicalSize.height / saved.logicalSize.height : 1
        var focusedID: PaneID?
        var toMinimize: [PaneID] = []

        for window in saved.windows {
            guard let kind = PaneKind(rawValue: window.kind) else { continue }
            let id = PaneID()
            let pane: any Pane = switch kind {
            case .terminal: TerminalPane(frame: .zero)
            case .browser: BrowserPane(frame: .zero)
            case .files: FilesPane(frame: .zero)
            case .notes: NotesPane(frame: .zero)
            }
            if let frame = window.frame {
                let scaled = CGRect(x: frame.minX * sx, y: frame.minY * sy,
                                    width: frame.width * sx, height: frame.height * sy)
                workspace.addFloating(pane, id: id, frame: clampWindow(scaled))
            } else {
                workspace.add(pane, id: id, focusedFrame: workspace.focused.flatMap { currentFrames()[$0] })
            }

            switch pane {
            case let browser as BrowserPane:
                browser.restore(urls: window.tabs ?? [], pinned: window.pinnedTabs ?? [], active: window.activeTab ?? 0)
            case let terminal as TerminalPane:
                terminal.restore(hosts: window.hosts ?? [], active: window.activeHost)
            case let files as FilesPane:
                if let location = window.location, let path = window.path {
                    files.restore(location: location, path: path)
                }
            default:
                break
            }
            if window.isMinimized { toMinimize.append(id) }
            if window.isFocused { focusedID = id }
        }
        for id in toMinimize {
            workspace.minimize(id)
        }
        if let focusedID { workspace.setFocus(focusedID) }
        services.desktop.notifyChange()
    }

    /// Crea un panel en el escritorio.
    func addPane(kind: PaneKind, autoStart: Bool = true) {
        let workspace = services.desktop.active
        let id = PaneID()
        let focusedFrame = workspace.focused.flatMap { currentFrames()[$0] }

        let pane: any Pane = switch kind {
        case .terminal: TerminalPane(frame: .zero)
        case .browser: BrowserPane(frame: .zero)
        case .files: FilesPane(frame: .zero)
        case .notes: NotesPane(frame: .zero)
        }

        if DesktopPreferences.newPanesFloat {
            workspace.addFloating(pane, id: id, frame: nextFloatingFrame())
        } else {
            workspace.add(pane, id: id, focusedFrame: focusedFrame)
        }
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

    /// Una sesión nueva en un panel de terminal: la lista de conexiones.
    ///
    /// **Ya no conecta por su cuenta.** Antes, con una sola máquina, entraba
    /// directamente, y había que cerrar lo que se había abierto sin pedirlo.
    func openTerminalSession(in pane: TerminalPane) {
        pane.showHome()
    }

    // MARK: - Lanzador

    private var launcher: Launcher?

    /// Ajustes, en el monitor: los globales o los de un tipo de panel.
    ///
    /// Tienen que estar aquí porque el iPhone, con pantalla externa, es sólo
    /// superficie táctil: si allí hubiera controles, el clic izquierdo acabaría
    /// pulsándolos en vez de llegar al escritorio.
    /// Ajustes, en una ventana más del escritorio (`SettingsPane`). Si ya
    /// hay una, pasa delante con lo que se pide.
    func presentSettings(_ scope: SettingsScope, page: Int = 0) {
        let workspace = services.desktop.active
        if let (id, pane) = settingsPaneEntry {
            pane.show(scope: scope, page: page)
            if let minimized = workspace.minimized.first(where: { $0.id == id }) {
                restoreMinimized(minimized.id)
            }
            workspace.setFocus(id)
            services.desktop.notifyChange()
            return
        }
        let pane = SettingsPane(scope: scope, page: page)
        let area = tileArea
        let size = CGSize(
            width: min(max(area.width * 0.55, 640), 900, area.width),
            height: min(max(area.height * 0.75, 420), 660, area.height)
        )
        let frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                           width: size.width, height: size.height)
        workspace.addFloating(pane, id: PaneID(), frame: clampWindow(frame))
        services.desktop.notifyChange()
    }

    func dismissSettings() {
        guard let (_, pane) = settingsPaneEntry else { return }
        closePane(pane)
    }

    /// La ventana de ajustes, si hay una abierta.
    private var settingsPaneEntry: (PaneID, SettingsPane)? {
        for (id, pane) in services.desktop.active.panes {
            if let settings = pane as? SettingsPane { return (id, settings) }
        }
        return nil
    }

    private var quickLook: QuickLookView?

    /// Vista previa con la barra espaciadora, como en el Finder.
    func presentQuickLook(for item: FileItem, from provider: any FileProvider) {
        quickLook?.removeFromSuperview()
        let view = QuickLookView(item: item, provider: provider, frame: CGRect(origin: .zero, size: logicalSize))
        view.onDismiss = { [weak self] in
            self?.quickLook?.removeFromSuperview()
            self?.quickLook = nil
        }
        canvas.addSubview(view)
        quickLook = view
    }

    /// Menú del clic derecho.
    func presentContextMenu(_ entries: [ContextMenu.Entry], at point: CGPoint) {
        contextMenu?.removeFromSuperview()
        guard !entries.isEmpty else { return }

        let menu = ContextMenu(
            entries: entries,
            at: point,
            in: CGRect(origin: .zero, size: logicalSize)
        )
        menu.onDismiss = { [weak self] in
            self?.contextMenu?.removeFromSuperview()
            self?.contextMenu = nil
        }
        canvas.addSubview(menu)
        contextMenu = menu
    }

    /// Lo mismo, pero desde dentro de un panel.
    ///
    /// El lienzo va escalado con un `CGAffineTransform`, así que un panel no
    /// puede convertir sus coordenadas a las del escritorio por su cuenta: se
    /// las pide aquí, que es quien conoce la jerarquía.
    func presentContextMenu(_ entries: [ContextMenu.Entry], from view: UIView, at point: CGPoint) {
        presentContextMenu(entries, at: canvas.convert(point, from: view))
    }

    private var prompt: PromptWindow?
    private var contextMenu: ContextMenu?

    /// Pide un texto: renombrar, crear carpeta.
    func presentPrompt(title: String, value: String, completion: @escaping (String?) -> Void) {
        prompt?.removeFromSuperview()
        let window = PromptWindow(
            title: title,
            value: value,
            frame: CGRect(origin: .zero, size: logicalSize)
        )
        window.onFinish = { [weak self] result in
            self?.prompt?.removeFromSuperview()
            self?.prompt = nil
            completion(result)
        }
        canvas.addSubview(window)
        prompt = window
    }

    /// Pide confirmación para algo que no se puede deshacer.
    func presentConfirm(
        title: String,
        message: String,
        destructive: String,
        isDestructive: Bool = true,
        completion: @escaping (Bool) -> Void
    ) {
        prompt?.removeFromSuperview()
        let window = PromptWindow(
            title: title,
            message: message,
            confirmTitle: destructive,
            destructive: isDestructive,
            frame: CGRect(origin: .zero, size: logicalSize)
        )
        window.onFinish = { [weak self] result in
            self?.prompt?.removeFromSuperview()
            self?.prompt = nil
            completion(result != nil)
        }
        canvas.addSubview(window)
        prompt = window
    }

    /// El botón rojo: cierra un panel, con lo que tenga dentro.
    func closePane(_ view: UIView) {
        let workspace = services.desktop.active
        if let (id, pane) = workspace.panes.first(where: { $0.value.view === view }).map({ ($0.key, $0.value) }) {
            (pane as? TerminalPane)?.closeAll()
            pane.view.removeFromSuperview()
            workspace.remove(id)
            // Sin pantalla completa que valga si ya no queda nada que enseñar.
            if workspace.isEmpty, services.desktop.isFullScreen {
                services.desktop.isFullScreen = false
            }
            services.desktop.notifyChange()
        }
    }

    /// El botón amarillo: el panel sale del mosaico y queda en el dock.
    func minimizePane(_ view: UIView) {
        let workspace = services.desktop.active
        guard let id = workspace.panes.first(where: { $0.value.view === view })?.key else { return }
        workspace.minimize(id)
        if workspace.isEmpty, services.desktop.isFullScreen {
            services.desktop.isFullScreen = false
        }
        services.desktop.notifyChange()
    }

    /// Pulsar un icono del dock, como en macOS: vuelven las ventanas
    /// minimizadas de la app; si no hay, pasa delante la de más delante; y si
    /// no tiene ninguna, se abre una. Si la app ya estaba delante, volver a
    /// pulsar abre otra ventana: lo pidió Bruno, y era lo que esperaba.
    private func openFromDock(_ kind: PaneKind) {
        let workspace = services.desktop.active
        let minimized = workspace.minimized.filter { PaneKind.of($0.pane) == kind }

        if !minimized.isEmpty {
            for entry in minimized {
                restoreMinimized(entry.id)
            }
        } else if let pane = workspace.focusedPane, PaneKind.of(pane) == kind {
            addPane(kind: kind)
        } else if let id = workspace.panes(of: kind).first {
            workspace.setFocus(id)
        } else {
            addPane(kind: kind)
        }
        services.desktop.notifyChange()
    }

    /// Botón derecho sobre un icono del dock, como en macOS: una ventana
    /// nueva de esa app y la lista de las que tiene abiertas, minimizadas
    /// incluidas, para ir directamente a una.
    private func dockMenu(for kind: PaneKind) -> [ContextMenu.Entry] {
        let desktop = services.desktop
        let workspace = desktop.active

        var entries = [ContextMenu.Entry(title: "Nueva ventana", symbol: "plus.rectangle") { [weak self] in
            self?.newPane(kind)
        }]
        for id in workspace.panes(of: kind) {
            guard let pane = workspace.pane(id) else { continue }
            entries.append(ContextMenu.Entry(title: pane.title, symbol: "macwindow") {
                workspace.setFocus(id)
                desktop.notifyChange()
            })
        }
        for entry in workspace.minimized where PaneKind.of(entry.pane) == kind {
            entries.append(ContextMenu.Entry(title: entry.pane.title, symbol: "dock.arrow.down.rectangle") {
                [weak self] in self?.restoreMinimized(entry.id)
            })
        }
        return entries
    }

    /// Devuelve un panel minimizado al escritorio y le pasa el foco.
    func restoreMinimized(_ id: PaneID) {
        let workspace = services.desktop.active
        let focusedFrame = workspace.focused.flatMap { currentFrames()[$0] }
        workspace.restore(id, focusedFrame: focusedFrame)
        services.desktop.notifyChange()
    }

    /// Da el foco a un panel. Los botones de ventana lo piden antes de actuar,
    /// porque maximizar y pantalla completa van sobre el panel con foco.
    func focus(_ view: UIView) {
        let workspace = services.desktop.active
        guard let id = workspace.panes.first(where: { $0.value.view === view })?.key,
              workspace.focused != id else { return }
        workspace.setFocus(id)
        services.desktop.notifyChange()
    }

    /// Enseña un fichero o una carpeta del iPhone en el gestor de ficheros.
    func revealInFiles(_ url: URL) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let directory = isDirectory.boolValue ? url.path : url.deletingLastPathComponent().path
        let name = isDirectory.boolValue ? nil : url.lastPathComponent

        (frontmost(.files) as? FilesPane)?.show(localDirectory: directory, selecting: name)
        services.desktop.notifyChange()
    }

    private var historyWindow: HistoryWindow?

    /// Los atajos del teclado con una ventana modal delante.
    ///
    /// **No pueden tocar lo de detrás.** Los atajos se ejecutan antes de que
    /// la tecla llegue a nadie, así que con el historial o el lanzador abiertos
    /// Cmd+V pegaba en el terminal de detrás —y un texto con un salto de línea
    /// es una orden que se ejecuta en el servidor— y Cmd+W cerraba una pestaña
    /// que no se veía. Ahora Cmd+V pega en la ventana, Cmd+Intro abre en otra
    /// pestaña desde el historial, y el resto no hace nada.
    ///
    /// Devuelve `nil` si no hay ninguna modal.
    private func performOverModal(_ command: DesktopCommand) -> Bool? {
        let modals: [UIView?] = [contextMenu, prompt, quickLook, hostEditor, historyWindow, launcher, overview, weatherPopover]
        guard modals.contains(where: { $0 != nil }) else { return nil }

        switch command {
        case .paste:
            guard let text = services.clipboard.readForPaste() else { return true }
            if let prompt { prompt.insertText(text) }
            else if let hostEditor { hostEditor.insertText(text) }
            else if let historyWindow { historyWindow.insertText(text) }
            else if let launcher { launcher.insertText(text) }
        case .toggleMaximize:
            historyWindow?.openSelected(newTab: true)
        case .history where historyWindow != nil:
            historyWindow?.onDismiss?()
        case .launcher where launcher != nil:
            launcher?.onDismiss?()
        default:
            break
        }
        return true
    }

    /// Cmd+Y: todo el historial, como en Safari.
    func presentHistory() {
        historyWindow?.removeFromSuperview()
        let window = HistoryWindow(frame: CGRect(origin: .zero, size: logicalSize))
        window.onDismiss = { [weak self] in
            self?.historyWindow?.removeFromSuperview()
            self?.historyWindow = nil
        }
        window.onOpen = { [weak self] url, newTab in
            guard let self else { return }
            if !newTab, let browser = self.services.desktop.active.focusedPane as? BrowserPane {
                browser.openInCurrentTab(url)
            } else {
                self.openInBrowser(url)
            }
        }
        canvas.addSubview(window)
        historyWindow = window
        applyContentsScale(to: window)
    }

    /// Una nota nueva en la ventana de Notas de más delante.
    func newNote(text: String = "") {
        (frontmost(.notes) as? NotesPane)?.newNote(text: text)
        services.desktop.notifyChange()
    }

    func openInBrowser(_ url: URL) {
        (frontmost(.browser) as? BrowserPane)?.newTab(url: url.absoluteString)
    }

    /// La ventana de una app en la que abrir algo: la de más delante del
    /// escritorio actual, con el foco; si no hay, una nueva aquí mismo. **No
    /// cambia de escritorio**: lo que se abre aparece donde se está mirando.
    private func frontmost(_ kind: PaneKind) -> (any Pane)? {
        let workspace = services.desktop.active
        if let id = workspace.panes(of: kind).first {
            workspace.setFocus(id)
        } else {
            addPane(kind: kind)
        }
        services.desktop.notifyChange()
        return workspace.focusedPane
    }

    private var hostEditor: FormWindow?

    /// Alta y edición de máquinas, también en el monitor.
    ///
    /// Antes vivían en el iPhone, pero el teléfono se apaga con pantalla
    /// externa: teclear allí obliga a dejar de mirar el monitor.
    func presentHostEditor(for host: SSHHost?) {
        presentForm(SSHHostForm(host: host))
    }

    /// Alta y edición de servidores SMB, con el mismo formulario.
    func presentSMBEditor(for server: SMBServer?) {
        presentForm(SMBServerForm(server: server))
    }

    private func presentForm(_ form: any EditorForm) {
        hostEditor?.removeFromSuperview()

        let editor = FormWindow(form: form, frame: CGRect(origin: .zero, size: logicalSize))
        editor.onDismiss = { [weak self] in
            self?.hostEditor?.removeFromSuperview()
            self?.hostEditor = nil
            self?.settingsPaneEntry?.1.refresh()
        }
        canvas.addSubview(editor)
        hostEditor = editor
    }

    /// Conecta el terminal con foco a una máquina. Lo usan los ajustes.
    func connectTerminal(to host: SSHHost) {
        connectFocusedTerminal(to: host)
    }

    /// Cmd+P: el lanzador, con todo lo que se puede abrir.
    func presentLauncher() {
        launcher?.removeFromSuperview()

        var entries: [Launcher.Entry] = []

        for host in services.hosts.hosts {
            entries.append(Launcher.Entry(
                title: host.displayName,
                subtitle: "SSH · \(host.username)@\(host.host)",
                symbol: "terminal"
            ) { [weak self] in
                self?.connectFocusedTerminal(to: host)
            })
        }

        for (index, provider) in services.files.providers.enumerated() {
            entries.append(Launcher.Entry(
                title: provider.name,
                subtitle: "Ficheros",
                symbol: provider.symbol
            ) { [weak self] in
                self?.showFilesLocation(index)
            })
        }
        entries.append(Launcher.Entry(title: "Descargas", subtitle: "Ficheros · iPhone", symbol: "arrow.down.circle") {
            [weak self] in self?.revealInFiles(BrowserTab.downloadsDirectory)
        })

        let history = services.history
        for page in history.bookmarks {
            entries.append(webEntry(page, symbol: "bookmark"))
        }
        let bookmarked = Set(history.bookmarks.map(\.url))
        for page in history.visits where !bookmarked.contains(page.url) {
            entries.append(webEntry(page, symbol: "clock"))
        }

        entries += [
            Launcher.Entry(title: "Nuevo terminal", subtitle: "Acción", symbol: "plus.rectangle") {
                [weak self] in self?.newPane(.terminal)
            },
            Launcher.Entry(title: "Nuevo navegador", subtitle: "Acción", symbol: "plus.rectangle") {
                [weak self] in self?.newPane(.browser)
            },
            Launcher.Entry(title: "Nuevo gestor de ficheros", subtitle: "Acción", symbol: "plus.rectangle") {
                [weak self] in self?.newPane(.files)
            },
            Launcher.Entry(title: "Nota nueva", subtitle: "Acción · Notas", symbol: "square.and.pencil") {
                [weak self] in self?.newNote()
            },
            Launcher.Entry(title: "Pantalla completa", subtitle: "Acción · Ctrl+Cmd+F", symbol: "arrow.up.left.and.arrow.down.right") {
                [weak self] in self?.perform(.toggleFullScreen)
            },
            Launcher.Entry(title: "Historial", subtitle: "Acción · Cmd+Y", symbol: "clock.arrow.circlepath") {
                [weak self] in self?.presentHistory()
            },
            Launcher.Entry(title: "Todas las ventanas", subtitle: "Acción · Cmd+E", symbol: "rectangle.3.group") {
                // Después de cerrarse el lanzador, que si no cuenta como modal.
                [weak self] in DispatchQueue.main.async { self?.toggleExpose() }
            },
            Launcher.Entry(title: "Ajustes", subtitle: "Acción", symbol: "gearshape") {
                [weak self] in self?.presentSettings(.global)
            },
        ]

        let launcher = Launcher(entries: entries) { [weak self] query in
            guard let self else { return [] }
            let text = query.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let url = BrowserTab.url(from: text) else { return [] }
            let isSearch = text.contains(" ") || !text.contains(".")
            return [Launcher.Entry(
                title: isSearch ? "Buscar «\(text)»" : "Abrir \(text)",
                subtitle: isSearch ? "Web · \(SearchEngine.current.label)" : "Web",
                symbol: isSearch ? "magnifyingglass" : "safari"
            ) { [weak self] in
                self?.openInBrowser(url)
            }]
        }
        launcher.onDismiss = { [weak self] in
            self?.launcher?.removeFromSuperview()
            self?.launcher = nil
        }
        canvas.addSubview(launcher)
        launcher.frame = CGRect(origin: .zero, size: logicalSize)
        self.launcher = launcher
        applyContentsScale(to: launcher)
    }

    private func webEntry(_ page: BrowserHistory.Page, symbol: String) -> Launcher.Entry {
        let host = URL(string: page.url)?.host() ?? page.url
        return Launcher.Entry(title: page.title, subtitle: "Web · \(host)", symbol: symbol) { [weak self] in
            guard let url = URL(string: page.url) else { return }
            self?.openInBrowser(url)
        }
    }

    /// Una ventana nueva de una app, en el escritorio en que se está.
    private func newPane(_ kind: PaneKind) {
        addPane(kind: kind)
    }

    private func showFilesLocation(_ index: Int) {
        (frontmost(.files) as? FilesPane)?.showProvider(at: index)
        services.desktop.notifyChange()
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

    /// Dónde está cada panel del escritorio: los del mosaico y los que
    /// flotan.
    private func currentFrames() -> [PaneID: CGRect] {
        let workspace = services.desktop.active
        return paneFrames(tiled: tiledFrames(), in: workspace)
    }

    private func tiledFrames() -> [PaneID: CGRect] {
        services.desktop.active.layout.frames(in: tileArea, gap: Tokens.Metric.tileGap)
    }

    private func paneFrames(tiled: [PaneID: CGRect], in workspace: Workspace) -> [PaneID: CGRect] {
        var frames = tiled
        for (id, frame) in workspace.floating {
            frames[id] = frame
        }
        return frames
    }

    /// Dónde se reparten los paneles: entre la barra y el dock.
    private var tileArea: CGRect {
        let gap = Tokens.Metric.tileGap
        if services.desktop.isFullScreen {
            return CGRect(origin: .zero, size: logicalSize).insetBy(dx: gap / 2, dy: gap / 2)
        }
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
        // El puntero no sabe qué teclas hay pulsadas: se miran en el teclado.
        let modifiers = modifiers.union(KeyboardRouter.heldModifiers)
        let position = services.pointer.position
        let frames = currentFrames()

        if case .moved = kind { updateCursorShape(at: position) }

        // El conmutador se confirma al soltar Cmd. Si esa tecla no llegara
        // (iOS no siempre avisa de un modificador suelto), el primer
        // movimiento del ratón sin Cmd hace lo mismo.
        if case .moved = kind, let overview, overview.style == .switcher, !modifiers.contains(.command) {
            endWindowSwitch()
        }
        if let overview, overview.handlePointer(kind, at: position) { return }

        // Lo modal manda, y la vista previa va por encima de todo.
        if let contextMenu, contextMenu.handlePointer(kind, at: position) { return }
        if let weatherPopover, weatherPopover.handlePointer(kind, at: position) { return }
        if let prompt, prompt.handlePointer(kind, at: position) { return }
        if let quickLook, quickLook.handlePointer(kind, at: position) { return }
        if let hostEditor, hostEditor.handlePointer(kind, at: position) { return }
        if let historyWindow, historyWindow.handlePointer(kind, at: position, modifiers: modifiers) { return }
        if let launcher, launcher.handlePointer(kind, at: position) { return }

        if fileDrag != nil, handleFileDrag(kind, at: position) { return }

        // Una ventana que se está arrastrando manda sobre el dock y la barra:
        // si no, al pasar por encima se quedarían el movimiento y la ventana
        // se pararía a medio camino.
        if windowDrag != nil, handleWindowDrag(kind, at: position) { return }

        if case .moved = kind, dockAutoHidden {
            updateFullScreenReveal(at: position)
        }
        if !dockAutoHidden || dockRevealed, handleDock(kind, at: position) { return }
        if !services.desktop.isFullScreen || topBarRevealed, handleTopBar(kind, at: position) { return }
        if handleWindowDrag(kind, at: position) { return }
        if floatingWindow(at: position) == nil,
           handleDivider(kind, at: position, frames: tiledFrames()) { return }

        guard let hit = paneHit(at: position, frames: frames) else { return }

        let workspace = services.desktop.active

        if case .down(let button) = kind, button == .right {
            let local = CGPoint(x: position.x - hit.value.minX, y: position.y - hit.value.minY)
            if workspace.focused != hit.key {
                workspace.setFocus(hit.key)
                services.desktop.notifyChange()
            }
            if let files = workspace.pane(hit.key) as? FilesPane {
                presentContextMenu(files.contextMenuEntries(at: local), at: position)
                return
            }
            if let notes = workspace.pane(hit.key) as? NotesPane {
                presentContextMenu(notes.contextMenuEntries(at: local), at: position)
                return
            }
            if let browser = workspace.pane(hit.key) as? BrowserPane {
                // Hay que preguntarle a la página qué hay bajo el cursor, y
                // eso es asíncrono: el menú sale en cuanto contesta.
                Task { [weak self] in
                    let entries = await browser.contextMenuEntries(at: local)
                    self?.presentContextMenu(entries, at: position)
                }
                return
            }
        }

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

    // MARK: - Ventanas flotantes

    /// Sombras de las ventanas flotantes. Van en una vista aparte, debajo de
    /// cada panel: los paneles recortan su contenido (`clipsToBounds`) para
    /// las esquinas redondeadas, y una sombra dentro de ellos se recortaría
    /// también.
    private var floatingShadows: [PaneID: UIView] = [:]

    /// Pone las flotantes encima del mosaico en su orden de apilamiento, y
    /// deja por encima de todo las barras y las ventanas modales.
    private func arrangeFloating(in workspace: Workspace, frames: [PaneID: CGRect]) {
        for (id, shadow) in floatingShadows where !workspace.isFloating(id) {
            shadow.removeFromSuperview()
            floatingShadows[id] = nil
        }
        for id in workspace.floatingOrder {
            guard let pane = workspace.pane(id), let frame = frames[id] else { continue }
            let shadow = floatingShadows[id] ?? {
                let view = UIView()
                view.isUserInteractionEnabled = false
                view.layer.shadowColor = UIColor.black.cgColor
                view.layer.shadowOpacity = 0.28
                view.layer.shadowRadius = 22
                view.layer.shadowOffset = CGSize(width: 0, height: 10)
                floatingShadows[id] = view
                return view
            }()
            shadow.frame = pixelAligned(frame)
            shadow.layer.shadowPath = UIBezierPath(
                roundedRect: shadow.bounds,
                cornerRadius: Tokens.Metric.paneCornerRadius
            ).cgPath
            canvas.addSubview(shadow)
            canvas.bringSubviewToFront(shadow)
            canvas.bringSubviewToFront(pane.view)
        }

        // Los paneles van debajo de las barras: con pantalla completa, el dock
        // y la barra salen por encima de lo que haya. Y las ventanas modales,
        // por encima de todo, incluidas las barras.
        canvas.bringSubviewToFront(topBar)
        canvas.bringSubviewToFront(dock)
        let modals: [UIView?] = [launcher, historyWindow, hostEditor, quickLook, prompt, contextMenu]
        for modal in modals.compactMap({ $0 }) {
            canvas.bringSubviewToFront(modal)
        }
    }

    /// La ventana flotante de más delante que hay en un punto.
    private func floatingWindow(at point: CGPoint, margin: CGFloat = 0) -> (PaneID, CGRect)? {
        let workspace = services.desktop.active
        for id in workspace.floatingOrder.reversed() {
            guard let frame = workspace.floating[id] else { continue }
            if frame.insetBy(dx: -margin, dy: -margin).contains(point) { return (id, frame) }
        }
        return nil
    }

    /// El panel que hay en un punto: primero las flotantes, de delante a
    /// atrás, y luego el mosaico.
    private func paneHit(at point: CGPoint, frames: [PaneID: CGRect]) -> (key: PaneID, value: CGRect)? {
        if let (id, frame) = floatingWindow(at: point) { return (id, frame) }
        let workspace = services.desktop.active
        return frames.first { !workspace.isFloating($0.key) && $0.value.contains(point) }
    }

    /// Bordes que se agarran al redimensionar.
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    private enum WindowDrag {
        /// Se ha pulsado la barra de un panel del mosaico, pero todavía no se
        /// ha movido lo bastante como para soltarlo: así un clic en la barra
        /// no lo saca del mosaico sin querer.
        case pending(id: PaneID, start: CGPoint, frame: CGRect)
        /// `start` es dónde se pulsó: una ventana encajada no recupera su
        /// tamaño hasta que el cursor se ha movido de verdad.
        case moving(id: PaneID, offset: CGPoint, start: CGPoint)
        case resizing(id: PaneID, edges: Edges, start: CGPoint, frame: CGRect)
    }

    private var windowDrag: WindowDrag?

    /// Las flotantes que se redimensionan a la vez que la arrastrada: las que
    /// tocan el borde que se mueve, con el suyo de enfrente y su marco al
    /// empezar. Lo pidió Bruno al encajar dos ventanas (24-sep-2026).
    private var linkedResize: [(id: PaneID, edge: Edges, frame: CGRect)] = []

    /// Qué ventanas están pegadas a los bordes que se van a mover. «Pegadas»
    /// es a la distancia del hueco del mosaico o menos, y solapando a lo largo
    /// del borde: así casan las encajadas, que dejan ese hueco entre ellas.
    private func neighbors(of id: PaneID, frame: CGRect, edges: Edges) -> [(id: PaneID, edge: Edges, frame: CGRect)] {
        let touch = Tokens.Metric.tileGap + 3
        var result: [(id: PaneID, edge: Edges, frame: CGRect)] = []
        for (other, candidate) in services.desktop.active.floating where other != id {
            let overlapsVertically = candidate.minY < frame.maxY - 20 && candidate.maxY > frame.minY + 20
            let overlapsHorizontally = candidate.minX < frame.maxX - 20 && candidate.maxX > frame.minX + 20
            if edges.contains(.right), overlapsVertically, abs(candidate.minX - frame.maxX) <= touch {
                result.append((other, .left, candidate))
            } else if edges.contains(.left), overlapsVertically, abs(candidate.maxX - frame.minX) <= touch {
                result.append((other, .right, candidate))
            } else if edges.contains(.bottom), overlapsHorizontally, abs(candidate.minY - frame.maxY) <= touch {
                result.append((other, .top, candidate))
            } else if edges.contains(.top), overlapsHorizontally, abs(candidate.maxY - frame.minY) <= touch {
                result.append((other, .bottom, candidate))
            }
        }
        return result
    }
    /// El último clic en una barra, para reconocer el doble clic.
    private var lastBarClick: (id: PaneID, time: Date)?

    private static let resizeMargin: CGFloat = 6
    private static let minimumWindowSize = CGSize(width: 340, height: 220)

    /// Arrastrar y redimensionar ventanas. Devuelve `true` si consumió el
    /// evento.
    private func handleWindowDrag(_ kind: PointerEvent.Kind, at position: CGPoint) -> Bool {
        let workspace = services.desktop.active

        switch kind {
        case .down(let button) where button == .left:
            // Los bordes de una flotante, lo primero: caen justo encima del
            // contenido del panel, y si no, el panel se los comería.
            if let (id, frame) = floatingWindow(at: position, margin: Self.resizeMargin) {
                let edges = resizeEdges(at: position, frame: frame)
                if !edges.isEmpty {
                    focusPane(id)
                    windowDrag = .resizing(id: id, edges: edges, start: position, frame: frame)
                    linkedResize = neighbors(of: id, frame: frame, edges: edges)
                    return true
                }
            }

            guard let hit = paneHit(at: position, frames: currentFrames()),
                  let pane = workspace.pane(hit.key)
            else { return false }
            let local = CGPoint(x: position.x - hit.value.minX, y: position.y - hit.value.minY)
            guard pane.isDragArea(local) else { return false }

            // Doble clic en la barra: del mosaico a flotante y al revés.
            let now = Date()
            if let last = lastBarClick, last.id == hit.key, now.timeIntervalSince(last.time) < 0.5 {
                lastBarClick = nil
                windowDrag = nil
                toggleFloating(hit.key)
                return true
            }
            lastBarClick = (hit.key, now)

            focusPane(hit.key)
            windowDrag = workspace.isFloating(hit.key)
                ? .moving(
                    id: hit.key,
                    offset: CGPoint(x: position.x - hit.value.minX, y: position.y - hit.value.minY),
                    start: position
                )
                : .pending(id: hit.key, start: position, frame: hit.value)
            return true

        case .moved:
            guard let drag = windowDrag else { return false }
            switch drag {
            case .pending(let id, let start, let frame):
                guard hypot(position.x - start.x, position.y - start.y) > 8 else { return true }
                // Se suelta del mosaico. Si el hueco era enorme, la ventana
                // sale algo más pequeña, pero siempre bajo el cursor y por el
                // mismo punto de la barra por el que se agarró.
                let area = tileArea
                let size = CGSize(
                    width: min(frame.width, area.width * 0.7),
                    height: min(frame.height, area.height * 0.75)
                )
                let grab = CGPoint(
                    x: (start.x - frame.minX) * size.width / frame.width,
                    y: start.y - frame.minY
                )
                let origin = CGPoint(x: position.x - grab.x, y: position.y - grab.y)
                workspace.float(id, frame: clampWindow(CGRect(origin: origin, size: size)))
                windowDrag = .moving(id: id, offset: grab, start: start)
                lastBarClick = nil
                layoutWithoutAnimation()

            case .moving(let id, var offset, let start):
                guard var frame = workspace.floating[id] else { windowDrag = nil; return true }
                // Una ventana encajada o maximizada que se arrastra vuelve a
                // su tamaño, bajo el cursor y por el mismo punto de la barra.
                if let previous = zoomRestore[id],
                   hypot(position.x - start.x, position.y - start.y) > 8 {
                    zoomRestore[id] = nil
                    offset.x *= previous.width / max(frame.width, 1)
                    frame.size = previous.size
                    windowDrag = .moving(id: id, offset: offset, start: start)
                }
                let origin = CGPoint(x: position.x - offset.x, y: position.y - offset.y)
                workspace.setFloatingFrame(id, clampWindow(CGRect(origin: origin, size: frame.size)))
                lastBarClick = nil
                updateSnapPreview(snapTarget(at: position), below: workspace.pane(id)?.view)
                layoutWithoutAnimation()

            case .resizing(let id, let edges, let start, let frame):
                let dx = position.x - start.x
                let dy = position.y - start.y
                let minimum = Self.minimumWindowSize
                var next = frame
                if edges.contains(.left) {
                    let width = max(minimum.width, frame.width - dx)
                    next.origin.x = frame.maxX - width
                    next.size.width = width
                }
                if edges.contains(.right) { next.size.width = max(minimum.width, frame.width + dx) }
                if edges.contains(.top) {
                    let height = max(minimum.height, frame.height - dy)
                    next.origin.y = frame.maxY - height
                    next.size.height = height
                }
                if edges.contains(.bottom) { next.size.height = max(minimum.height, frame.height + dy) }
                next = clampWindow(next)
                // Las que están pegadas por ese borde lo siguen, como dos
                // ventanas encajadas lado a lado: lo que gana una lo pierde la
                // otra. Si la de al lado ya no puede encoger más, se para todo.
                var moved: [(PaneID, CGRect)] = []
                for (other, edge, original) in linkedResize {
                    var follower = original
                    switch edge {
                    case .left:
                        follower.origin.x = original.minX + (next.maxX - frame.maxX)
                        follower.size.width = original.maxX - follower.minX
                    case .right:
                        follower.size.width = original.width + (next.minX - frame.minX)
                    case .top:
                        follower.origin.y = original.minY + (next.maxY - frame.maxY)
                        follower.size.height = original.maxY - follower.minY
                    default:
                        follower.size.height = original.height + (next.minY - frame.minY)
                    }
                    guard follower.width >= minimum.width, follower.height >= minimum.height else { return true }
                    moved.append((other, follower))
                }
                workspace.setFloatingFrame(id, next)
                for (other, follower) in moved {
                    workspace.setFloatingFrame(other, follower)
                }
                layoutWithoutAnimation()
            }
            return true

        case .up:
            guard let drag = windowDrag else { return false }
            windowDrag = nil
            linkedResize = []
            if case .moving(let id, _, _) = drag, let snap = snapTarget(at: position),
               let frame = workspace.floating[id] {
                // Se recuerda dónde estaba para devolverla al arrastrarla
                // otra vez, o con el botón verde.
                if zoomRestore[id] == nil { zoomRestore[id] = frame }
                workspace.setFloatingFrame(id, snapFrame(snap))
            }
            updateSnapPreview(nil, below: nil)
            services.desktop.notifyChange()
            return true

        default:
            return false
        }
    }

    /// La doble flecha sobre lo que se puede redimensionar: el borde de una
    /// flotante o un divisor del mosaico. Mientras se arrastra, se mantiene
    /// aunque el cursor se adelante al borde.
    private func updateCursorShape(at position: CGPoint) {
        services.pointer.shape = cursorShape(at: position)
    }

    private func cursorShape(at position: CGPoint) -> PointerController.Shape {
        if case .resizing(_, let edges, _, _) = windowDrag { return Self.shape(for: edges) }
        if let divider = activeDivider { return Self.shape(for: divider.axis) }
        guard windowDrag == nil, fileDrag == nil else { return .arrow }

        let modals: [UIView?] = [launcher, historyWindow, hostEditor, quickLook, prompt, contextMenu, overview, weatherPopover]
        guard modals.allSatisfy({ $0 == nil }) else { return .arrow }

        if let (_, frame) = floatingWindow(at: position, margin: Self.resizeMargin) {
            return Self.shape(for: resizeEdges(at: position, frame: frame))
        }
        if let divider = divider(at: position, frames: tiledFrames()) {
            return Self.shape(for: divider.axis)
        }
        return .arrow
    }

    private static func shape(for edges: Edges) -> PointerController.Shape {
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        switch (horizontal, vertical) {
        case (true, true):
            let falling = (edges.contains(.left) && edges.contains(.top))
                || (edges.contains(.right) && edges.contains(.bottom))
            return falling ? .resizeDiagonalDown : .resizeDiagonalUp
        case (true, false): return .resizeHorizontal
        case (false, true): return .resizeVertical
        case (false, false): return .arrow
        }
    }

    /// Un divisor de un contenedor horizontal es una raya vertical, que se
    /// mueve a los lados.
    private static func shape(for axis: LayoutContainer.Axis) -> PointerController.Shape {
        axis == .horizontal ? .resizeHorizontal : .resizeVertical
    }

    private func resizeEdges(at point: CGPoint, frame: CGRect) -> Edges {
        let margin = Self.resizeMargin
        var edges: Edges = []
        if abs(point.x - frame.minX) <= margin { edges.insert(.left) }
        if abs(point.x - frame.maxX) <= margin { edges.insert(.right) }
        if abs(point.y - frame.minY) <= margin { edges.insert(.top) }
        if abs(point.y - frame.maxY) <= margin { edges.insert(.bottom) }
        // Fuera del alto o el ancho de la ventana no hay borde que agarrar.
        let withinX = point.x >= frame.minX - margin && point.x <= frame.maxX + margin
        let withinY = point.y >= frame.minY - margin && point.y <= frame.maxY + margin
        return withinX && withinY ? edges : []
    }

    /// Una ventana nunca se pierde: la barra queda siempre a la vista y
    /// siempre queda un trozo dentro de la pantalla para poder recuperarla.
    private func clampWindow(_ frame: CGRect) -> CGRect {
        let top = services.desktop.isFullScreen ? 0 : Tokens.Metric.topBarHeight
        var result = frame
        result.size.width = min(result.width, logicalSize.width)
        result.size.height = min(result.height, logicalSize.height - top)
        result.origin.y = min(max(result.minY, top), logicalSize.height - 40)
        result.origin.x = min(max(result.minX, 100 - result.width), logicalSize.width - 100)
        return result
    }

    private func layoutWithoutAnimation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutCanvas()
        CATransaction.commit()
    }

    private func focusPane(_ id: PaneID) {
        let workspace = services.desktop.active
        guard workspace.focused != id else {
            workspace.raise(id)
            return
        }
        workspace.setFocus(id)
        services.desktop.notifyChange()
    }

    /// Del mosaico a flotante y al revés. Cmd+Mayús+Espacio y doble clic en
    /// la barra.
    func toggleFloating(_ id: PaneID) {
        let workspace = services.desktop.active
        if workspace.isFloating(id) {
            let neighbor = workspace.layout.panes.first
            workspace.tile(id, nextTo: neighbor, neighborFrame: neighbor.flatMap { tiledFrames()[$0] })
            zoomRestore[id] = nil
        } else {
            let area = tileArea
            let current = tiledFrames()[id] ?? area
            let size = CGSize(
                width: max(Self.minimumWindowSize.width, min(current.width, area.width * 0.62)),
                height: max(Self.minimumWindowSize.height, min(current.height, area.height * 0.7))
            )
            let frame = CGRect(
                x: current.midX - size.width / 2,
                y: current.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            workspace.float(id, frame: clampWindow(frame))
        }
        workspace.setFocus(id)
        services.desktop.notifyChange()
    }

    /// Dónde sale una ventana nueva cuando los paneles nuevos flotan: centrada
    /// y en cascada, para que no se tape una con otra exactamente.
    private func nextFloatingFrame() -> CGRect {
        let area = tileArea
        let size = CGSize(
            width: max(Self.minimumWindowSize.width, area.width * 0.6),
            height: max(Self.minimumWindowSize.height, area.height * 0.7)
        )
        let step = CGFloat(services.desktop.active.floating.count % 6) * 28
        return clampWindow(CGRect(
            x: area.midX - size.width / 2 + step,
            y: area.midY - size.height / 2 + step,
            width: size.width,
            height: size.height
        ))
    }

    // MARK: - Encajar ventanas

    /// Adónde va una ventana soltada en un borde, como en macOS y Windows:
    /// a media pantalla en los lados, a un cuarto en las esquinas y a toda
    /// arriba. Bruno pidió mitades y cuartos (24-sep-2026).
    private enum Snap {
        case left, right, full
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private var snapPreview: UIView?

    /// El cursor no sale del escritorio, así que «en el borde» es tocarlo.
    ///
    /// Las esquinas son generosas (80 puntos a lo largo del borde): acertar
    /// el píxel exacto de una esquina con un ratón es imposible.
    private func snapTarget(at position: CGPoint) -> Snap? {
        let edge: CGFloat = 3
        let corner: CGFloat = 80
        let atLeft = position.x <= edge
        let atRight = position.x >= logicalSize.width - 1 - edge
        let atTop = position.y <= edge
        let atBottom = position.y >= logicalSize.height - 1 - edge
        let nearTop = position.y <= corner
        let nearBottom = position.y >= logicalSize.height - corner
        let nearLeft = position.x <= corner
        let nearRight = position.x >= logicalSize.width - corner

        if (atLeft && nearTop) || (atTop && nearLeft) { return .topLeft }
        if (atRight && nearTop) || (atTop && nearRight) { return .topRight }
        if (atLeft && nearBottom) || (atBottom && nearLeft) { return .bottomLeft }
        if (atRight && nearBottom) || (atBottom && nearRight) { return .bottomRight }
        if atLeft { return .left }
        if atRight { return .right }
        if atTop { return .full }
        return nil
    }

    private func snapFrame(_ snap: Snap) -> CGRect {
        // Hasta abajo del todo: el dock se aparta (ver `dockIsCovered`).
        var area = tileArea
        area.size.height = logicalSize.height - Tokens.Metric.tileGap / 2 - area.minY
        let gap = Tokens.Metric.tileGap
        let half = (area.width - gap) / 2
        let halfHeight = (area.height - gap) / 2
        let left = area.minX
        let right = area.maxX - half
        let top = area.minY
        let bottom = area.maxY - halfHeight
        return switch snap {
        case .left: CGRect(x: left, y: top, width: half, height: area.height)
        case .right: CGRect(x: right, y: top, width: half, height: area.height)
        case .full: area
        case .topLeft: CGRect(x: left, y: top, width: half, height: halfHeight)
        case .topRight: CGRect(x: right, y: top, width: half, height: halfHeight)
        case .bottomLeft: CGRect(x: left, y: bottom, width: half, height: halfHeight)
        case .bottomRight: CGRect(x: right, y: bottom, width: half, height: halfHeight)
        }
    }

    /// El hueco donde va a quedar, detrás de la ventana que se arrastra.
    private func updateSnapPreview(_ snap: Snap?, below window: UIView?) {
        guard let snap else {
            if let preview = snapPreview {
                snapPreview = nil
                UIView.animate(withDuration: 0.12, animations: { preview.alpha = 0 }) { _ in
                    preview.removeFromSuperview()
                }
            }
            return
        }
        let frame = snapFrame(snap)
        if let preview = snapPreview {
            guard preview.frame != frame else { return }
            UIView.animate(withDuration: 0.15) { preview.frame = frame }
            return
        }
        let preview = UIView(frame: frame.insetBy(dx: frame.width * 0.05, dy: frame.height * 0.05))
        preview.backgroundColor = Tokens.Color.accent.withAlphaComponent(0.14)
        preview.layer.cornerRadius = Tokens.Metric.paneCornerRadius
        preview.layer.borderWidth = 1.5
        preview.setThemedBorder(Tokens.Color.accent.withAlphaComponent(0.6))
        preview.isUserInteractionEnabled = false
        preview.alpha = 0
        if let window, window.superview === canvas {
            canvas.insertSubview(preview, belowSubview: window)
        } else {
            canvas.addSubview(preview)
        }
        snapPreview = preview
        UIView.animate(withDuration: 0.15) {
            preview.alpha = 1
            preview.frame = frame
        }
    }

    /// Dónde estaba cada flotante antes de maximizarla, para devolverla.
    private var zoomRestore: [PaneID: CGRect] = [:]

    /// Maximizar una flotante: ocupa el área del mosaico, o la pantalla entera
    /// con `fullScreen`. Si ya lo estaba, vuelve a su tamaño.
    private func toggleZoom(_ id: PaneID, fullScreen: Bool) {
        let workspace = services.desktop.active
        guard let frame = workspace.floating[id] else { return }
        if let previous = zoomRestore[id] {
            zoomRestore[id] = nil
            workspace.setFloatingFrame(id, previous)
        } else {
            zoomRestore[id] = frame
            workspace.setFloatingFrame(id, fullScreen ? CGRect(origin: .zero, size: logicalSize) : tileArea)
        }
    }

    // MARK: - Cambiar de ventana y Exposé

    /// Exposé o el conmutador, cuando están abiertos. Ver `WindowOverview`.
    private var overview: WindowOverview?

    /// Si hay otra ventana modal delante: entonces ni el conmutador ni
    /// Exposé se abren, que taparían algo a medio hacer.
    private var hasOtherModal: Bool {
        let modals: [UIView?] = [contextMenu, prompt, quickLook, hostEditor, historyWindow, launcher, weatherPopover]
        return modals.contains { $0 != nil }
    }

    /// Todas las ventanas, por orden de uso: la que tiene el foco, la de
    /// antes… y al final las minimizadas que nunca tuvieron foco.
    private func overviewEntries() -> [WindowOverview.Entry] {
        let workspace = services.desktop.active
        let frames = currentFrames()
        let minimizedIDs = workspace.minimized.map(\.id)

        var order = workspace.recent.filter { workspace.pane($0) != nil || minimizedIDs.contains($0) }
        for id in workspace.floatingOrder.reversed() + workspace.layout.panes + minimizedIDs
        where !order.contains(id) {
            order.append(id)
        }

        return order.compactMap { id in
            if let pane = workspace.pane(id) {
                // Un panel tapado por el maximizado no está en pantalla: sale
                // sin foto, como uno minimizado.
                let onScreen = pane.view.window != nil && frames[id] != nil
                let frame = frames[id] ?? pane.view.bounds
                return WindowOverview.Entry(
                    id: id,
                    title: pane.title,
                    kind: PaneKind.of(pane),
                    frame: frame,
                    snapshot: onScreen ? pane.view.snapshotView(afterScreenUpdates: false) : nil,
                    isMinimized: false
                )
            }
            guard let entry = workspace.minimized.first(where: { $0.id == id }) else { return nil }
            return WindowOverview.Entry(
                id: id,
                title: entry.pane.title,
                kind: PaneKind.of(entry.pane),
                frame: entry.frame ?? entry.pane.view.bounds,
                snapshot: nil,
                isMinimized: true
            )
        }
    }

    private func presentOverview(_ style: WindowOverview.Style, entries: [WindowOverview.Entry], selected: Int) {
        overview?.removeFromSuperview()
        let view = WindowOverview(style: style, entries: entries, selected: selected)
        view.frame = CGRect(origin: .zero, size: logicalSize)
        view.onPick = { [weak self] id in self?.pickWindow(id) }
        view.onDismiss = { [weak self] in self?.dismissOverview() }
        canvas.addSubview(view)
        overview = view
        applyContentsScale(to: view)
        // Delante del cursor no: el cursor es una capa aparte, siempre encima.
        services.pointer.shape = .arrow
    }

    private func dismissOverview() {
        overview?.removeFromSuperview()
        overview = nil
    }

    /// Cmd+º: abre el conmutador en la ventana de antes o, si ya está
    /// abierto, pasa a la siguiente.
    private func cycleWindows(backwards: Bool) {
        if let overview {
            if overview.style == .switcher { overview.advance(by: backwards ? -1 : 1) }
            return
        }
        guard !hasOtherModal else { return }
        let entries = overviewEntries()
        guard entries.count > 1 else { return }
        presentOverview(.switcher, entries: entries, selected: backwards ? entries.count - 1 : 1)
    }

    /// Se soltó Cmd: a la ventana elegida.
    private func endWindowSwitch() {
        guard let overview, overview.style == .switcher else { return }
        if let id = overview.selectedID {
            pickWindow(id)
        } else {
            dismissOverview()
        }
    }

    /// Cmd+E: abre o cierra Exposé.
    func toggleExpose() {
        if overview != nil {
            dismissOverview()
            return
        }
        guard !hasOtherModal else { return }
        let entries = overviewEntries()
        guard !entries.isEmpty else { return }
        presentOverview(.expose, entries: entries, selected: 0)
    }

    /// Lleva a una ventana: le da el foco y la trae delante; si estaba en el
    /// dock, la saca; si otro panel del mosaico estaba maximizado y la tapa,
    /// deja de estarlo.
    private func pickWindow(_ id: PaneID) {
        dismissOverview()
        let workspace = services.desktop.active
        if workspace.minimized.contains(where: { $0.id == id }) {
            restoreMinimized(id)
            return
        }
        guard workspace.pane(id) != nil else { return }
        if let maximized = workspace.layout.maximized, maximized != id, !workspace.isFloating(id) {
            workspace.layout.maximized = nil
        }
        workspace.setFocus(id)
        services.desktop.notifyChange()
    }

    // MARK: - Arrastrar ficheros

    private struct FileDrag {
        var items: [FileItem]
        var provider: any FileProvider
        weak var source: FilesPane?
        var ghost: UIView
        weak var target: FilesPane?
    }

    private var fileDrag: FileDrag?

    /// Un panel de Ficheros empieza a arrastrar algo. A partir de aquí el
    /// escritorio lleva el cursor: el arrastre puede acabar en otro panel.
    func beginFileDrag(_ items: [FileItem], from provider: any FileProvider, source: FilesPane) {
        guard let item = items.first else { return }
        let ghost = UILabel()
        let icon = NSTextAttachment()
        icon.image = UIImage(
            systemName: items.count > 1 ? "doc.on.doc.fill" : (item.isDirectory ? "folder.fill" : "doc.fill"),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        )?.withTintColor(Tokens.Color.accent.resolvedColor(with: traitCollection), renderingMode: .alwaysOriginal)
        let text = NSMutableAttributedString(attachment: icon)
        text.append(NSAttributedString(string: "  " + (items.count > 1 ? "\(items.count) elementos" : item.name), attributes: [
            .font: Tokens.sans(12.5, weight: .medium),
            .foregroundColor: Tokens.Color.text,
        ]))
        ghost.attributedText = text
        ghost.textAlignment = .center
        ghost.backgroundColor = Tokens.Color.panelElevated.withAlphaComponent(0.95)
        ghost.layer.cornerRadius = 8
        ghost.layer.masksToBounds = true
        ghost.setThemedBorder(Tokens.Color.accent.withAlphaComponent(0.6))
        ghost.layer.borderWidth = 1
        let size = ghost.intrinsicContentSize
        ghost.frame.size = CGSize(width: min(size.width + 24, 320), height: 28)
        canvas.addSubview(ghost)
        applyContentsScale(to: ghost)
        fileDrag = FileDrag(items: items, provider: provider, source: source, ghost: ghost, target: nil)
        moveGhost(to: services.pointer.position)
    }

    private func moveGhost(to position: CGPoint) {
        guard let ghost = fileDrag?.ghost else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.frame.origin = CGPoint(x: position.x + 14, y: position.y + 10)
        canvas.bringSubviewToFront(ghost)
        CATransaction.commit()
    }

    /// El panel de Ficheros bajo el cursor y el punto en sus coordenadas.
    private func filesPane(at position: CGPoint) -> (FilesPane, CGPoint)? {
        guard let hit = paneHit(at: position, frames: currentFrames()),
              let pane = services.desktop.active.pane(hit.key) as? FilesPane
        else { return nil }
        return (pane, CGPoint(x: position.x - hit.value.minX, y: position.y - hit.value.minY))
    }

    private func handleFileDrag(_ kind: PointerEvent.Kind, at position: CGPoint) -> Bool {
        guard var drag = fileDrag else { return false }
        switch kind {
        case .moved:
            moveGhost(to: position)
            let found = filesPane(at: position)
            if drag.target !== found?.0 { drag.target?.highlightDrop(nil) }
            found?.0.highlightDrop(found.map { $0.0.dropTarget(at: $0.1) } ?? nil)
            drag.target = found?.0
            fileDrag = drag

        case .up:
            drag.ghost.removeFromSuperview()
            drag.target?.highlightDrop(nil)
            fileDrag = nil
            if let (pane, local) = filesPane(at: position), let target = pane.dropTarget(at: local) {
                pane.drop(drag.items, from: drag.provider, at: target)
            }

        default:
            break
        }
        return true
    }

    /// Tras mover algo entre paneles, que los dos enseñen lo que hay ahora.
    func refreshFilesPanes() {
        for (_, pane) in services.desktop.active.panes {
            (pane as? FilesPane)?.refresh()
        }
    }

    // MARK: - Pantalla completa

    /// El dock asoma al llevar el cursor al borde de abajo, y la barra al de
    /// arriba, como en macOS. Se esconden al alejarse.
    private var dockRevealed = false
    private var topBarRevealed = false
    /// El dock se esconde solo: con pantalla completa o si una ventana ocupa
    /// su sitio.
    private var dockAutoHidden = false

    /// Si alguna ventana pisa el sitio de la barra del dock.
    private func dockIsCovered() -> Bool {
        let width = max(dock.barWidth, 200)
        let bar = CGRect(
            x: (logicalSize.width - width) / 2,
            y: logicalSize.height - Dock.height - Dock.bottomMargin,
            width: width,
            height: Dock.height
        )
        let workspace = services.desktop.active
        return currentFrames().contains { id, frame in
            workspace.pane(id) != nil && frame.intersects(bar)
        }
    }

    private func updateFullScreenReveal(at position: CGPoint) {
        let edge: CGFloat = 3
        let wantsDock = dockRevealed
            ? position.y > logicalSize.height - Dock.height - Dock.bottomMargin - 24
            : position.y >= logicalSize.height - edge
        // La barra de arriba sólo se esconde con pantalla completa.
        let wantsTopBar = services.desktop.isFullScreen && (topBarRevealed
            ? position.y < Tokens.Metric.topBarHeight + 16
            : position.y <= edge)
        guard wantsDock != dockRevealed || wantsTopBar != topBarRevealed else { return }
        dockRevealed = wantsDock
        topBarRevealed = wantsTopBar
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.layoutCanvas()
        }
    }

    /// Clics en el dock. Devuelve `true` si consumió el evento.
    private func handleDock(_ kind: PointerEvent.Kind, at position: CGPoint) -> Bool {
        let pointInDock = CGPoint(x: position.x - dock.frame.minX, y: position.y - dock.frame.minY)
        guard dock.frame.contains(position), dock.contains(point: pointInDock) else { return false }
        guard case .down(let button) = kind else { return true }

        if button == .right, let kind = dock.kind(at: pointInDock) {
            presentContextMenu(dockMenu(for: kind), at: position)
        } else if dock.hitsSettings(pointInDock) {
            dock.onSettings?()
        } else if let kind = dock.kind(at: pointInDock) {
            openFromDock(kind)
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
            presentSettings(.global, page: 1)
        case .tailscale:
            let frame = topBar.itemFrame(.tailscale)
            presentContextMenu(tailscaleMenu(), at: CGPoint(x: frame.minX, y: topBar.frame.maxY))
        case .weather:
            let frame = topBar.itemFrame(.weather)
            presentWeather(anchor: CGPoint(x: frame.midX, y: topBar.frame.maxY))
        case .none:
            break
        }
        return true
    }

    // MARK: - Tailscale y el tiempo

    /// El menú de Tailscale: el estado, conectar o desconectar por Atajos y
    /// cómo preparar el atajo la primera vez.
    private func tailscaleMenu() -> [ContextMenu.Entry] {
        let tailscale = services.tailscale
        tailscale.refresh()
        let up = tailscale.isLikelyUp
        var entries = [
            ContextMenu.Entry(
                title: up ? "Tailscale conectado" : "Tailscale desconectado",
                symbol: up ? "checkmark.circle.fill" : "xmark.circle",
                isEnabled: false
            ) {},
            ContextMenu.Entry(title: up ? "Desconectar" : "Conectar", symbol: "power") {
                tailscale.toggle(on: !up)
            },
        ]
        if tailscale.lastToggle == .missingShortcut {
            entries.append(ContextMenu.Entry(
                title: "Falta el atajo «\(TailscaleMonitor.shortcutName)»",
                symbol: "exclamationmark.triangle",
                isEnabled: false
            ) {})
        }
        entries.append(ContextMenu.Entry(title: "Cómo crear el atajo…", symbol: "questionmark.circle") {
            [weak self] in self?.explainTailscaleShortcut()
        })
        return entries
    }

    private func explainTailscaleShortcut() {
        presentConfirm(
            title: "Atajo «\(TailscaleMonitor.shortcutName)»",
            message: "iOS no deja que una app encienda la VPN de otra, pero la app de Tailscale trae "
                + "acciones para Atajos. Crea en Atajos uno que se llame «\(TailscaleMonitor.shortcutName)» "
                + "con la acción de Tailscale para conectar o desconectar (o alternar). BrunOS le pasa "
                + "«on» u «off» como entrada, por si quieres decidir con un «Si». Al lanzarlo, el "
                + "iPhone pasa un momento por Atajos y vuelve solo.",
            destructive: "Abrir Atajos",
            isDestructive: false
        ) { open in
            guard open, let url = URL(string: "shortcuts://create-shortcut") else { return }
            UIApplication.shared.open(url)
        }
    }

    private var weatherPopover: WeatherPopover?

    private func presentWeather(anchor: CGPoint) {
        dismissWeather()
        let popover = WeatherPopover(anchor: anchor, in: CGRect(origin: .zero, size: logicalSize))
        popover.onDismiss = { [weak self] in self?.dismissWeather() }
        popover.onChangePlace = { [weak self] in
            self?.dismissWeather()
            self?.askWeatherPlace(anchor: anchor)
        }
        canvas.addSubview(popover)
        weatherPopover = popover
        applyContentsScale(to: popover)
        services.weather.refresh()
    }

    private func dismissWeather() {
        weatherPopover?.removeFromSuperview()
        weatherPopover = nil
    }

    /// Pide la ciudad por nombre y, si hay varias con ese nombre, deja elegir.
    private func askWeatherPlace(anchor: CGPoint) {
        presentPrompt(title: "Ciudad para el tiempo", value: services.weather.place?.name ?? "") { [weak self] name in
            guard let self, let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            Task {
                let places = (try? await WeatherService.search(name)) ?? []
                switch places.count {
                case 0:
                    self.presentConfirm(
                        title: "No encuentro «\(name)»",
                        message: "Prueba con otro nombre, o con el de la ciudad más cercana.",
                        destructive: "Vale",
                        isDestructive: false
                    ) { _ in }
                case 1:
                    self.services.weather.setPlace(places[0])
                    self.presentWeather(anchor: anchor)
                default:
                    let entries = places.map { place in
                        ContextMenu.Entry(
                            title: place.detail.isEmpty ? place.name : "\(place.name) · \(place.detail)",
                            symbol: "mappin.and.ellipse"
                        ) { [weak self] in
                            self?.services.weather.setPlace(place)
                            self?.presentWeather(anchor: anchor)
                        }
                    }
                    self.presentContextMenu(entries, at: CGPoint(x: anchor.x - 100, y: anchor.y))
                }
            }
        }
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
        if let overview, overview.handleKey(event) { return }
        if let contextMenu, contextMenu.handleKey(event) { return }
        if let weatherPopover, weatherPopover.handleKey(event) { return }
        if let prompt, prompt.handleKey(event) { return }
        if let quickLook, quickLook.handleKey(event) { return }
        if let hostEditor, hostEditor.handleKey(event) { return }
        if let historyWindow, historyWindow.handleKey(event) { return }
        if launcherHandlesKey(event) { return }
        services.desktop.active.focusedPane?.handleKey(event)
    }

    /// Entrega texto de golpe al panel con foco: dictado o pegar.
    func insertText(_ text: String) {
        services.desktop.active.focusedPane?.insertText(text)
    }
}
