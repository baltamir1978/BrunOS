import CoreGraphics
import Foundation

/// Identificador estable de un panel dentro de un espacio de trabajo.
struct PaneID: Hashable, Codable, Sendable {
    let raw: UUID
    init() { raw = UUID() }
}

/// Árbol de mosaico al estilo de i3: cada contenedor reparte su espacio entre
/// sus hijos a lo largo de un eje, y cada hijo es o un panel o otro contenedor.
///
/// El reparto se guarda en **fracciones, nunca en píxeles**. Es lo que permite
/// que al cambiar de monitor, de escala o de overscan el mosaico se vea igual
/// en proporción en vez de descuadrarse.
indirect enum LayoutNode: Codable, Equatable, Sendable {
    case pane(PaneID)
    case container(LayoutContainer)

    /// Todos los paneles que cuelgan de este nodo, de izquierda a derecha.
    var panes: [PaneID] {
        switch self {
        case .pane(let id):
            [id]
        case .container(let container):
            container.children.flatMap(\.panes)
        }
    }

    func contains(_ id: PaneID) -> Bool {
        panes.contains(id)
    }
}

struct LayoutContainer: Codable, Equatable, Sendable {
    enum Axis: Codable, Sendable {
        /// Los hijos se reparten el ancho: uno al lado del otro.
        case horizontal
        /// Los hijos se reparten el alto: uno encima del otro.
        case vertical

        var perpendicular: Axis {
            self == .horizontal ? .vertical : .horizontal
        }
    }

    var axis: Axis
    var children: [LayoutNode]
    /// Una fracción por hijo. Siempre suman 1.
    var fractions: [Double]

    init(axis: Axis, children: [LayoutNode], fractions: [Double]? = nil) {
        self.axis = axis
        self.children = children
        if let fractions, fractions.count == children.count {
            self.fractions = LayoutContainer.normalized(fractions)
        } else {
            let share = children.isEmpty ? 0 : 1 / Double(children.count)
            self.fractions = Array(repeating: share, count: children.count)
        }
    }

    static func normalized(_ values: [Double]) -> [Double] {
        let total = values.reduce(0, +)
        guard total > 0 else {
            let share = values.isEmpty ? 0 : 1 / Double(values.count)
            return Array(repeating: share, count: values.count)
        }
        return values.map { $0 / total }
    }
}

/// Reparte el espacio y resuelve las operaciones del gestor de ventanas.
///
/// Es lógica pura sobre valores: no toca UIKit, no sabe de vistas y no guarda
/// estado más allá del árbol. Así el mosaico se puede razonar —y más adelante
/// probar— sin necesidad de una pantalla conectada.
struct TilingLayout: Codable, Equatable, Sendable {

    /// Raíz del árbol. `nil` cuando el espacio de trabajo está vacío.
    private(set) var root: LayoutNode?

    /// Panel maximizado, que ocupa todo el espacio y tapa al resto.
    /// Es el equivalente al modo *fullscreen* de i3, no una ventana flotante.
    var maximized: PaneID?

    var panes: [PaneID] { root?.panes ?? [] }
    var isEmpty: Bool { root == nil }

    init(root: LayoutNode? = nil) {
        self.root = root
    }

    // MARK: - Reparto del espacio

    /// Calcula el rectángulo de cada panel dentro de `bounds`, en puntos lógicos.
    ///
    /// La separación entre paneles se descuenta del reparto, de modo que los
    /// paneles quedan separados por `gap` sin que se salga nada del borde.
    func frames(in bounds: CGRect, gap: CGFloat) -> [PaneID: CGRect] {
        if let maximized, root?.contains(maximized) == true {
            return [maximized: bounds]
        }
        guard let root else { return [:] }
        var result: [PaneID: CGRect] = [:]
        layout(node: root, in: bounds, gap: gap, into: &result)
        return result
    }

    private func layout(
        node: LayoutNode,
        in rect: CGRect,
        gap: CGFloat,
        into result: inout [PaneID: CGRect]
    ) {
        switch node {
        case .pane(let id):
            result[id] = rect

        case .container(let container):
            guard !container.children.isEmpty else { return }

            let gapTotal = gap * CGFloat(container.children.count - 1)
            let available = container.axis == .horizontal
                ? max(0, rect.width - gapTotal)
                : max(0, rect.height - gapTotal)

            var offset: CGFloat = container.axis == .horizontal ? rect.minX : rect.minY
            for (index, child) in container.children.enumerated() {
                let length = available * container.fractions[index]
                let childRect = container.axis == .horizontal
                    ? CGRect(x: offset, y: rect.minY, width: length, height: rect.height)
                    : CGRect(x: rect.minX, y: offset, width: rect.width, height: length)
                layout(node: child, in: childRect, gap: gap, into: &result)
                offset += length + gap
            }
        }
    }

    // MARK: - Insertar y quitar

    /// Añade un panel partiendo el espacio del que tiene el foco.
    ///
    /// Como en i3, el eje de la partición depende de la forma del hueco: un
    /// panel ancho se parte en vertical y uno alto en horizontal, que es lo que
    /// uno espera al mirar la pantalla.
    mutating func insert(_ id: PaneID, nextTo focused: PaneID?, focusedFrame: CGRect?) {
        guard let root else {
            self.root = .pane(id)
            return
        }
        guard let focused, root.contains(focused) else {
            // Sin foco válido, se cuelga del contenedor raíz.
            self.root = appendToRoot(root, id: id)
            return
        }

        let axis: LayoutContainer.Axis = if let frame = focusedFrame, frame.height > frame.width {
            .vertical
        } else {
            .horizontal
        }
        self.root = split(node: root, target: focused, newPane: id, axis: axis)
    }

    private func appendToRoot(_ node: LayoutNode, id: PaneID) -> LayoutNode {
        switch node {
        case .pane:
            .container(LayoutContainer(axis: .horizontal, children: [node, .pane(id)]))
        case .container(var container):
            {
                container.children.append(.pane(id))
                container.fractions = LayoutContainer.normalized(
                    container.fractions + [container.fractions.max() ?? 1]
                )
                return .container(container)
            }()
        }
    }

    private func split(
        node: LayoutNode,
        target: PaneID,
        newPane: PaneID,
        axis: LayoutContainer.Axis
    ) -> LayoutNode {
        switch node {
        case .pane(let id) where id == target:
            return .container(LayoutContainer(axis: axis, children: [node, .pane(newPane)]))

        case .pane:
            return node

        case .container(var container):
            // Si el objetivo es un hijo directo y el eje coincide, se mete
            // como hermano en vez de anidar otro contenedor: así el árbol no
            // se llena de contenedores de un solo uso.
            if container.axis == axis,
               let index = container.children.firstIndex(where: { $0 == .pane(target) }) {
                let share = container.fractions[index] / 2
                container.children.insert(.pane(newPane), at: index + 1)
                container.fractions[index] = share
                container.fractions.insert(share, at: index + 1)
                container.fractions = LayoutContainer.normalized(container.fractions)
                return .container(container)
            }

            container.children = container.children.map {
                split(node: $0, target: target, newPane: newPane, axis: axis)
            }
            return .container(container)
        }
    }

    /// Quita un panel y devuelve su espacio a los hermanos.
    mutating func remove(_ id: PaneID) {
        if maximized == id { maximized = nil }
        root = remove(id, from: root)
    }

    private func remove(_ id: PaneID, from node: LayoutNode?) -> LayoutNode? {
        guard let node else { return nil }
        switch node {
        case .pane(let existing):
            return existing == id ? nil : node

        case .container(var container):
            var children: [LayoutNode] = []
            var fractions: [Double] = []
            for (index, child) in container.children.enumerated() {
                if let kept = remove(id, from: child) {
                    children.append(kept)
                    fractions.append(container.fractions[index])
                }
            }
            switch children.count {
            case 0: return nil
            // Un contenedor con un solo hijo no aporta nada: se colapsa.
            case 1: return children[0]
            default:
                container.children = children
                container.fractions = LayoutContainer.normalized(fractions)
                return .container(container)
            }
        }
    }

    // MARK: - Mover el foco y los paneles

    enum Direction {
        case left, right, up, down

        var axis: LayoutContainer.Axis {
            switch self {
            case .left, .right: .horizontal
            case .up, .down: .vertical
            }
        }

        var isForward: Bool {
            self == .right || self == .down
        }
    }

    /// Panel vecino en una dirección, según la geometría ya calculada.
    ///
    /// Se resuelve por posición en pantalla y no recorriendo el árbol: es lo que
    /// hace que el movimiento coincida con lo que se ve, incluso con el mosaico
    /// anidado de formas raras.
    func pane(from id: PaneID, direction: Direction, frames: [PaneID: CGRect]) -> PaneID? {
        guard let origin = frames[id] else { return nil }
        let center = CGPoint(x: origin.midX, y: origin.midY)

        let candidates = frames.filter { key, frame in
            guard key != id else { return false }
            return switch direction {
            case .left: frame.midX < origin.midX && frame.maxY > origin.minY && frame.minY < origin.maxY
            case .right: frame.midX > origin.midX && frame.maxY > origin.minY && frame.minY < origin.maxY
            case .up: frame.midY < origin.midY && frame.maxX > origin.minX && frame.minX < origin.maxX
            case .down: frame.midY > origin.midY && frame.maxX > origin.minX && frame.minX < origin.maxX
            }
        }

        return candidates.min {
            hypot($0.value.midX - center.x, $0.value.midY - center.y)
                < hypot($1.value.midX - center.x, $1.value.midY - center.y)
        }?.key
    }

    /// Intercambia dos paneles de sitio. Es lo que hace Cmd+Shift+flecha.
    mutating func swap(_ a: PaneID, _ b: PaneID) {
        guard a != b, let root else { return }
        self.root = swap(a, b, in: root)
    }

    private func swap(_ a: PaneID, _ b: PaneID, in node: LayoutNode) -> LayoutNode {
        switch node {
        case .pane(let id):
            if id == a { return .pane(b) }
            if id == b { return .pane(a) }
            return node
        case .container(var container):
            container.children = container.children.map { swap(a, b, in: $0) }
            return .container(container)
        }
    }

    // MARK: - Divisores

    /// Mueve el divisor que separa a `pane` de su hermano en un eje.
    ///
    /// `delta` es una fracción del contenedor, no píxeles: el arrastre del ratón
    /// se convierte a fracción antes de llamar aquí, y así lo guardado sigue
    /// siendo independiente de la resolución.
    mutating func resize(pane: PaneID, axis: LayoutContainer.Axis, delta: Double) {
        guard let root else { return }
        self.root = resize(node: root, pane: pane, axis: axis, delta: delta)
    }

    private func resize(
        node: LayoutNode,
        pane: PaneID,
        axis: LayoutContainer.Axis,
        delta: Double
    ) -> LayoutNode {
        guard case .container(var container) = node else { return node }

        if container.axis == axis,
           let index = container.children.firstIndex(where: { $0.contains(pane) }),
           index + 1 < container.children.count {
            // No se deja que un panel se coma al vecino del todo.
            let minimum = 0.08
            let grow = min(
                max(delta, minimum - container.fractions[index]),
                container.fractions[index + 1] - minimum
            )
            container.fractions[index] += grow
            container.fractions[index + 1] -= grow
            return .container(container)
        }

        container.children = container.children.map {
            resize(node: $0, pane: pane, axis: axis, delta: delta)
        }
        return .container(container)
    }
}
