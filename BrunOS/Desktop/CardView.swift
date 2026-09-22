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
@MainActor
final class CardView: UIView {

    var drawContent: ((CGContext) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.translateBy(x: -frame.minX, y: -frame.minY)
        drawContent?(context)
    }
}
