import UIKit

/// La tarjeta de una ventana modal, que dibuja su propio contenido.
///
/// **Existe por un fallo que dejó los ajustes en blanco.** Las ventanas
/// dibujaban sus filas en el `draw(_:)` de la vista de fondo y ponían la tarjeta
/// como subvista. Pero una vista dibuja su contenido **debajo** de sus
/// subvistas, así que la tarjeta, que es opaca, tapaba todo lo dibujado: sólo
/// se veían el título y el aspa, que sí eran subvistas de la tarjeta.
///
/// Ahora dibuja la tarjeta. `drawContent` recibe el contexto ya desplazado a
/// las coordenadas de la ventana, así que el código de dibujo de cada ventana
/// no ha tenido que cambiar sus cuentas.
///
/// **El fondo y el contenido se recortan a las esquinas redondeadas.** Lo
/// dibujado en `draw(_:)` no respeta `cornerRadius`, y `masksToBounds` se
/// llevaría la sombra por delante: el fondo oscuro asomaba en cuadrado por las
/// esquinas del borde redondeado (Bruno lo vio en los ajustes de Ficheros). Así
/// que `backgroundColor` no va a la capa: lo pinta la propia tarjeta, dentro del
/// mismo recorte que el resto.
@MainActor
final class CardView: UIView {

    var drawContent: ((CGContext) -> Void)?

    private var fillColor: UIColor?

    override var backgroundColor: UIColor? {
        get { fillColor }
        set {
            fillColor = newValue
            super.backgroundColor = nil
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Sin contenido opaco en la capa, la sombra se calcularía píxel a
        // píxel; con el contorno dado sale igual y cuesta nada.
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let shape = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius)
        context.addPath(shape.cgPath)
        context.clip()
        if let fillColor {
            context.setFillColor(fillColor.desktopCGColor)
            context.fill(bounds)
        }
        context.translateBy(x: -frame.minX, y: -frame.minY)
        drawContent?(context)
    }
}
