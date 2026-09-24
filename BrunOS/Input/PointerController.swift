import QuartzCore
import UIKit

/// Ajustes de ratón que Bruno toca desde la interfaz del iPhone.
struct PointerSettings: Codable, Equatable, Sendable {

    /// Multiplica el desplazamiento que entrega la fuente.
    ///
    /// **Se multiplica con la velocidad de seguimiento de iOS**, la de
    /// Accesibilidad › Control del puntero. Conviene subir aquella y dejar ésta
    /// cerca de 1, porque lo que llega ya viene acelerado por el sistema; si se
    /// sube sólo ésta, el cursor da saltos.
    var sensitivity: Double = 1.0
    var scrollSpeed: Double = 1.0
    /// Aceleración del puntero. Con el puntero indirecto conviene dejarla
    /// puesta: sin ella hace falta recorrer más pantalla de iPhone de la que
    /// hay para cruzar el escritorio.
    var acceleration: Bool = true
    /// Scroll natural: el contenido sigue al dedo, como en macOS por defecto.
    var naturalScrolling: Bool = true

    static let key = "input.pointer"

    static func load(from defaults: UserDefaults = .standard) -> PointerSettings {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(PointerSettings.self, from: data)
        else { return PointerSettings() }
        return stored
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Elige sola entre las dos fuentes de ratón y reenvía lo que llegue.
///
/// Prefiere `GCMouse` si entrega, y si no el puntero indirecto (ver
/// `preferred`). La decisión no es de una vez para siempre: se rehace cada vez
/// que una fuente empieza o deja de entregar.
@MainActor
final class MouseRouter: MouseSourceDelegate {

    /// A quién le llegan los eventos ya elegidos.
    weak var delegate: (any MouseSourceDelegate)?

    private let gcSource = GCMouseSource()
    let indirectSource = IndirectPointerSource()

    /// Cuál está mandando ahora mismo, para Ajustes › Ratón y teclado.
    var activeSourceName: String {
        switch preferred {
        case let value as GCMouseSource where value === gcSource: "GCMouse"
        case let value as IndirectPointerSource where value === indirectSource: "puntero indirecto"
        default: "ninguna"
        }
    }

    /// Cuántos eventos ha entregado cada fuente. Sirve para distinguir, desde
    /// los ajustes del iPhone, entre "el ratón no llega a la app" y "llega pero
    /// el cursor no se mueve", que se parecen mucho y se arreglan distinto.
    private(set) var gcEventCount = 0
    private(set) var indirectEventCount = 0

    func start() {
        gcSource.delegate = self
        indirectSource.delegate = self
        gcSource.start()
        indirectSource.start()
    }

    func stop() {
        gcSource.stop()
        indirectSource.stop()
    }

    /// La fuente que manda: `GCMouse` si entrega, si no el puntero indirecto.
    ///
    /// **Es la preferencia con la que el ratón iba bien** (la 2609241352,
    /// según Bruno). El 24-sep se probó poner el indirecto delante, pensando
    /// que `GCMouse` era lo que atascaba el cursor, y fue a peor: tirones y sin
    /// llegar al borde. Lo que había estropeado la 2609241450 era el modo
    /// mando en negro forzado, ya quitado. **No cambiar esto sin datos**:
    /// Ajustes › Ratón y teclado › Diagnóstico dice qué fuente entrega y hasta
    /// dónde llega el puntero.
    private var preferred: (any MouseSource)? {
        if gcSource.isDelivering { return gcSource }
        if indirectSource.isDelivering { return indirectSource }
        return nil
    }


    private func isActive(_ source: any MouseSource) -> Bool {
        preferred === source
    }

    // MARK: - Diagnóstico

    /// Hasta dónde ha llegado el puntero indirecto, de 0 a 1 en cada eje,
    /// desde que se puso a cero. Si no llega a 0 o a 1 en algún lado, iOS no
    /// deja que el puntero cubra la pantalla entera del iPhone, y el cursor no
    /// llegará a ese borde del monitor (Bruno, 24-sep-2026).
    private(set) var indirectRange: (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat)?

    /// Eventos de movimiento de cada fuente en el último segundo, para ver si
    /// llegan las dos a la vez y cada cuánto.
    private var recentMoves: [(time: CFTimeInterval, gc: Bool)] = []

    var movesPerSecond: (gc: Int, indirect: Int) {
        let now = CACurrentMediaTime()
        let recent = recentMoves.filter { now - $0.time < 1 }
        return (recent.filter(\.gc).count, recent.filter { !$0.gc }.count)
    }

    func resetDiagnostics() {
        indirectRange = nil
        recentMoves = []
    }

    private func noteMove(_ source: any MouseSource, _ delta: MouseDelta) {
        let now = CACurrentMediaTime()
        recentMoves.append((now, source === gcSource))
        if recentMoves.count > 400 { recentMoves.removeFirst(recentMoves.count - 400) }
        guard source === indirectSource, let position = delta.position else { return }
        if var range = indirectRange {
            range.minX = min(range.minX, position.x)
            range.maxX = max(range.maxX, position.x)
            range.minY = min(range.minY, position.y)
            range.maxY = max(range.maxY, position.y)
            indirectRange = range
        } else {
            indirectRange = (position.x, position.x, position.y, position.y)
        }
    }

    func mouseSource(_ source: any MouseSource, didMove delta: MouseDelta) {
        count(source)
        noteMove(source, delta)
        guard isActive(source) else { return }
        delegate?.mouseSource(source, didMove: delta)
    }

    /// Se cuenta **antes** de filtrar por fuente activa: interesa saber si los
    /// eventos llegan, aunque acaben descartándose.
    private func count(_ source: any MouseSource) {
        if source === gcSource {
            gcEventCount += 1
        } else if source === indirectSource {
            indirectEventCount += 1
        }
        // Que el ratón entregue eventos manda sobre lo que diga el sistema de
        // AssistiveTouch: si funciona, sobra el aviso.
        AppServices.shared.assistiveTouch.notePointerEvent()
    }

    /// Los botones **pasan siempre, venga la fuente que venga**.
    ///
    /// El movimiento sí se filtra, para que dos fuentes no muevan el cursor a la
    /// vez y vaya al doble de velocidad. Pero con los botones el filtro hacía
    /// daño: si `GCMouse` entrega el movimiento y los clics llegan por el
    /// puntero indirecto, el filtro los tiraba y **hacer clic no hacía nada**.
    /// Un clic duplicado es un incordio; un clic perdido deja la app inservible.
    func mouseSource(_ source: any MouseSource, didPress button: PointerEvent.Button) {
        count(source)
        delegate?.mouseSource(source, didPress: button)
    }

    func mouseSource(_ source: any MouseSource, didRelease button: PointerEvent.Button) {
        delegate?.mouseSource(source, didRelease: button)
    }

    func mouseSourceDidChangeAvailability(_ source: any MouseSource) {
        delegate?.mouseSourceDidChangeAvailability(source)
    }
}

/// El cursor de BrunOS: una capa encima de todo lo demás en la ventana externa.
///
/// El cursor se dibuja a mano porque **la pantalla externa no es interactiva** y
/// iOS no pinta ahí ningún puntero. Su posición se lleva en puntos lógicos del
/// escritorio, no en píxeles, para que sobreviva a los cambios de escala.
///
/// El repintado va contra el `CADisplayLink` **de la escena externa**, para
/// seguir su refresco y no el del iPhone. Ojo: en iOS 27
/// `UIScreen.displayLink(withTarget:selector:)` quedó obsoleto y hay que pedirlo
/// a `UIWindowScene`.
@MainActor
final class PointerController {

    /// Posición del cursor en puntos lógicos del escritorio.
    private(set) var position: CGPoint = .zero

    /// Límites del escritorio en puntos lógicos.
    var bounds: CGRect = .zero {
        didSet { clampIntoBounds() }
    }

    var settings = PointerSettings.load()

    private let layer = CALayer()
    private let shapeLayer = CAShapeLayer()
    private var displayLink: CADisplayLink?
    /// La posición que falta por pintar.
    ///
    /// **El refresco se pausa con el ratón quieto**, que a 60 o 120 fotogramas
    /// por segundo sin moverse es batería y calor para nada. Pero **no al
    /// instante**: la primera versión pausaba en cuanto no había nada que
    /// pintar, o sea entre fotograma y fotograma mientras se movía, y un
    /// `CADisplayLink` reanudado puede tardar un fotograma en volver: el
    /// cursor daba tirones (Bruno, 24-sep-2026). Ahora se pausa tras medio
    /// segundo sin movimiento (`idleFrames`).
    private var pendingPosition: CGPoint? {
        didSet {
            guard pendingPosition != nil else { return }
            idleFrames = 0
            if displayLink?.isPaused == true { displayLink?.isPaused = false }
        }
    }
    private var idleFrames = 0
    private weak var hostLayer: CALayer?

    init() {
        buildCursor()
    }

    // MARK: - Instalación

    /// Coloca el cursor **dentro del lienzo lógico**, no sobre la ventana.
    ///
    /// Es importante y costó verlo: la posición del cursor se lleva en puntos
    /// lógicos del escritorio, pero la ventana está en puntos físicos. Colgando
    /// la capa de la ventana, un cursor en el centro del escritorio aparecía
    /// arriba a la izquierda y más pequeño de la cuenta, porque le faltaba el
    /// factor de escala que sí tiene el lienzo.
    ///
    /// Dentro del lienzo las coordenadas coinciden sin conversiones y el cursor
    /// se escala igual que todo lo demás.
    func attach(to canvas: UIView, scene: UIWindowScene?) {
        hostLayer = canvas.layer
        canvas.layer.addSublayer(layer)
        // Por encima de cualquier panel.
        layer.zPosition = 10_000

        displayLink?.invalidate()
        displayLink = scene?.displayLink(target: self, selector: #selector(step))
        displayLink?.add(to: .main, forMode: .common)
    }

    func detach() {
        displayLink?.invalidate()
        displayLink = nil
        layer.removeFromSuperlayer()
        hostLayer = nil
    }

    // MARK: - Movimiento

    /// Aplica un desplazamiento relativo. No repinta: eso lo hace el display
    /// link, para no dibujar más veces de las que la pantalla puede mostrar.
    ///
    /// Lleva **aceleración**, como cualquier sistema operativo de escritorio: un
    /// movimiento lento va casi 1:1, para poder apuntar a un divisor de 8 pt; uno
    /// rápido se multiplica, para cruzar la pantalla de un manotazo.
    ///
    /// Aquí no es un lujo, es necesario. Con el puntero indirecto, el recorrido
    /// físico disponible **es la pantalla del iPhone**: cuando el puntero del
    /// sistema llega a su borde deja de haber desplazamiento y el cursor se
    /// planta. Cuanto menos recorrido haga falta, menos se nota ese tope.
    func move(by delta: CGVector) {
        let speed = hypot(delta.dx, delta.dy)
        let gain = settings.sensitivity * acceleration(for: speed)

        let next = CGPoint(
            x: position.x + delta.dx * gain,
            y: position.y + delta.dy * gain
        )
        position = clamp(next)
        pendingPosition = position
    }

    /// Coloca el cursor en una posición del escritorio, dada de 0 a 1 en cada
    /// eje. La usa el puntero indirecto, que va en absoluto.
    func move(toNormalized point: CGPoint) {
        position = clamp(CGPoint(
            x: bounds.minX + point.x * bounds.width,
            y: bounds.minY + point.y * bounds.height
        ))
        pendingPosition = position
    }

    /// El botón del ratón está pulsado sobre el trackpad del iPhone. Mientras
    /// tanto, la posición del puntero no se aplica: si iOS la siguiera
    /// mandando, el cursor recibiría dos movimientos a la vez y daría saltos.
    var isHoldingButton = false

    /// Desplaza el cursor tal cual, sin sensibilidad ni aceleración: para
    /// seguir un movimiento que ya viene escalado al escritorio.
    func move(toDesktopDelta delta: CGVector) {
        position = clamp(CGPoint(x: position.x + delta.dx, y: position.y + delta.dy))
        pendingPosition = position
    }

    /// Curva de aceleración: 1× parado y hasta 3,5× a toda velocidad.
    ///
    /// El umbral está en puntos por evento, no por segundo, porque los eventos
    /// llegan al ritmo del refresco y el reparto sale parecido.
    private func acceleration(for speed: CGFloat) -> CGFloat {
        guard settings.acceleration else { return 1 }
        let threshold: CGFloat = 2
        guard speed > threshold else { return 1 }
        return min(1 + (speed - threshold) / 6, 3.5)
    }

    /// Recoloca el cursor dentro de la pantalla. Se llama al conectar un
    /// monitor, al cambiar de resolución y al cambiar la escala.
    func center() {
        position = CGPoint(x: bounds.midX, y: bounds.midY)
        pendingPosition = position
        step()
    }

    /// Convierte un scroll de la fuente al que espera el panel, aplicando
    /// velocidad y dirección.
    func scrollDelta(from raw: CGVector) -> CGVector {
        let sign: CGFloat = settings.naturalScrolling ? 1 : -1
        return CGVector(
            dx: raw.dx * settings.scrollSpeed * sign,
            dy: raw.dy * settings.scrollSpeed * sign
        )
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX - 1),
            y: min(max(point.y, bounds.minY), bounds.maxY - 1)
        )
    }

    private func clampIntoBounds() {
        position = clamp(position)
        pendingPosition = position
    }

    @objc private func step() {
        guard let pending = pendingPosition else {
            idleFrames += 1
            if idleFrames > 30 { displayLink?.isPaused = true }
            return
        }
        pendingPosition = nil
        // Sin animación implícita: si no, cada movimiento se interpola durante
        // un cuarto de segundo y el cursor va flotando por detrás del ratón.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = pending
        CATransaction.commit()
    }

    // MARK: - Dibujo

    /// La forma del cursor. La flecha de siempre, o la doble flecha de
    /// redimensionar sobre el borde de una ventana flotante o un divisor.
    enum Shape: Equatable {
        case arrow
        /// ↔, para un borde izquierdo o derecho.
        case resizeHorizontal
        /// ↕, para un borde de arriba o de abajo.
        case resizeVertical
        /// ⤡, esquinas de arriba a la izquierda y de abajo a la derecha.
        case resizeDiagonalDown
        /// ⤢, las otras dos esquinas.
        case resizeDiagonalUp
    }

    var shape: Shape = .arrow {
        didSet {
            guard shape != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyShape()
            CATransaction.commit()
        }
    }

    private func applyShape() {
        switch shape {
        case .arrow:
            shapeLayer.path = Self.arrowPath.cgPath
            layer.bounds = CGRect(x: 0, y: 0, width: 14, height: 22)
            // El ancla en la punta: la flecha apunta con la esquina.
            layer.anchorPoint = .zero
        case .resizeHorizontal, .resizeVertical, .resizeDiagonalDown, .resizeDiagonalUp:
            let angle: CGFloat = switch shape {
            case .resizeVertical: .pi / 2
            case .resizeDiagonalDown: .pi / 4
            case .resizeDiagonalUp: -.pi / 4
            default: 0
            }
            let path = Self.doubleArrowPath
            path.apply(CGAffineTransform(rotationAngle: angle))
            path.apply(CGAffineTransform(translationX: 12, y: 12))
            shapeLayer.path = path.cgPath
            layer.bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
            // La doble flecha apunta con su centro, como en macOS.
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }
    }

    private static var arrowPath: UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 18))
        path.addLine(to: CGPoint(x: 4.4, y: 13.8))
        path.addLine(to: CGPoint(x: 7.2, y: 20.4))
        path.addLine(to: CGPoint(x: 10, y: 19.2))
        path.addLine(to: CGPoint(x: 7.2, y: 12.8))
        path.addLine(to: CGPoint(x: 12.6, y: 12.6))
        path.close()
        return path
    }

    /// ↔ centrada en el origen; las otras direcciones se sacan girándola.
    private static var doubleArrowPath: UIBezierPath {
        let points: [CGPoint] = [
            CGPoint(x: -10, y: 0), CGPoint(x: -5, y: -5), CGPoint(x: -5, y: -1.5),
            CGPoint(x: 5, y: -1.5), CGPoint(x: 5, y: -5), CGPoint(x: 10, y: 0),
            CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 1.5), CGPoint(x: -5, y: 1.5),
            CGPoint(x: -5, y: 5),
        ]
        let path = UIBezierPath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.close()
        return path
    }

    /// Sólida clara con reborde oscuro, para que se lea igual sobre el fondo
    /// casi negro del escritorio y sobre una página web blanca.
    private func buildCursor() {
        // El cursor no cambia con el modo: claro con borde negro se ve igual
        // sobre un fondo claro que sobre uno oscuro, y así no hay que repintarlo.
        shapeLayer.fillColor = Tokens.Color.text.cgColor(for: .dark)
        shapeLayer.strokeColor = UIColor.black.withAlphaComponent(0.85).cgColor
        shapeLayer.lineWidth = 1
        shapeLayer.lineJoin = .round
        layer.addSublayer(shapeLayer)
        applyShape()

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }
}
