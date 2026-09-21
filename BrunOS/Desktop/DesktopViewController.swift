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
        canvas.backgroundColor = Tokens.Color.background
        view.addSubview(canvas)

        canvas.addSubview(topBar)

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

    private func layoutCanvas() {
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

        let workspace = services.desktop.active
        let gap = Tokens.Metric.tileGap
        let area = CGRect(
            x: gap,
            y: Tokens.Metric.topBarHeight + gap,
            width: max(0, logicalSize.width - 2 * gap),
            height: max(0, logicalSize.height - Tokens.Metric.topBarHeight - 2 * gap)
        )

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

        // Éstas son del panel con foco, no del escritorio. Llegarán a su sitio
        // cuando existan el terminal, el navegador y los ficheros.
        case .newTab, .closeTab, .launcher, .addressBar, .reload, .find,
             .zoomIn, .zoomOut, .zoomReset:
            Log.desktop.debug("Orden aún sin destino: \(String(describing: command))")
            return false
        }

        services.desktop.notifyChange()
        return true
    }

    /// Crea un panel en el espacio activo.
    func addPane(kind: PaneKind) {
        let workspace = services.desktop.active
        let id = PaneID()
        let focusedFrame = workspace.focused.flatMap { currentFrames()[$0] }
        workspace.add(PlaceholderPane(kind: kind), id: id, focusedFrame: focusedFrame)
        services.desktop.notifyChange()
    }

    private func currentFrames() -> [PaneID: CGRect] {
        let gap = Tokens.Metric.tileGap
        let area = CGRect(
            x: gap,
            y: Tokens.Metric.topBarHeight + gap,
            width: max(0, logicalSize.width - 2 * gap),
            height: max(0, logicalSize.height - Tokens.Metric.topBarHeight - 2 * gap)
        )
        return services.desktop.active.layout.frames(in: area, gap: gap)
    }

    // MARK: - Puntero

    /// Instala el cursor sobre esta ventana y lo centra.
    func attachPointer() {
        guard let window = view.window else { return }
        services.pointer.attach(to: window)
        // El cursor se dibuja en la ventana, que está en puntos físicos, así que
        // su capa tiene que llevar la misma escala que el lienzo.
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
        services.desktop.active.focusedPane?.handleKey(event)
    }

    /// Entrega texto de golpe al panel con foco: dictado o pegar.
    func insertText(_ text: String) {
        services.desktop.active.focusedPane?.insertText(text)
    }
}
