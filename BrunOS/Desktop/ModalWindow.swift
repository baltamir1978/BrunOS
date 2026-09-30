import UIKit

/// Una ventana modal del escritorio: menú contextual, diálogos, historial,
/// lanzador, vista previa, Exposé, el tiempo, el calendario.
///
/// Ocupa el lienzo entero (lo de fuera de su tarjeta también es suyo: un clic
/// ahí la cierra), va por encima de todo y, mientras está abierta, se queda el
/// ratón y el teclado. El escritorio las recorre con `openModals`, que es la
/// **única lista**: antes cada una se apuntaba a mano en seis sitios.
@MainActor
protocol ModalWindow: UIView {
    /// Devuelve `true` si se queda el evento.
    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) -> Bool
    func handleKey(_ event: KeyEvent) -> Bool
}

extension WindowOverview: ModalWindow {}
extension ContextMenu: ModalWindow {}
extension PromptWindow: ModalWindow {}
extension CalendarPopover: ModalWindow {}
extension WeatherPopover: ModalWindow {}
extension QuickLookView: ModalWindow {}
extension FormWindow: ModalWindow {}
extension Launcher: ModalWindow {}

extension HistoryWindow: ModalWindow {
    /// Sin modificadores. El escritorio le pasa los de verdad por la otra,
    /// para Cmd+clic (abrir en otra pestaña).
    func handlePointer(_ kind: PointerEvent.Kind, at point: CGPoint) -> Bool {
        handlePointer(kind, at: point, modifiers: [])
    }
}
