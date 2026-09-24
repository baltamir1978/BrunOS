import QuartzCore
import UIKit

/// Lo que enseña Ajustes › Acerca de › Rendimiento: si la app va fluida, cuánto
/// trabaja y cuánta memoria gasta.
///
/// Sin el Modo de desarrollador del iPhone no se puede usar Instruments, así
/// que para saber si una optimización sirve de algo hacía falta verlo desde
/// dentro. **Sólo mide mientras esa página está abierta**: medir también
/// cuesta, y un contador de fotogramas encendido siempre sería justo lo que se
/// quiere evitar.
@MainActor
final class PerformanceMonitor: NSObject {

    static let shared = PerformanceMonitor()

    /// Fotogramas por segundo del hilo principal en la pantalla externa.
    /// Cuando algo lo bloquea, el refresco llega tarde y bajan.
    private(set) var framesPerSecond = 0
    /// El fotograma más lento del último segundo, en milisegundos. Es lo que
    /// se nota como un tirón aunque la media sea buena.
    private(set) var worstFrame: Double = 0
    /// Cuántas veces por segundo se recoloca el escritorio entero.
    private(set) var layoutsPerSecond = 0

    private var displayLink: CADisplayLink?
    private var frames = 0
    private var layouts = 0
    private var slowest: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0

    var isRunning: Bool { displayLink != nil }

    func start(on scene: UIWindowScene?) {
        guard displayLink == nil, let scene else { return }
        let link = scene.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        displayLink = link
        frames = 0
        layouts = 0
        slowest = 0
        lastTimestamp = 0
        windowStart = CACurrentMediaTime()
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// La llama `layoutCanvas()` cada vez que se ejecuta.
    func noteLayout() {
        guard displayLink != nil else { return }
        layouts += 1
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp > 0 {
            slowest = max(slowest, link.timestamp - lastTimestamp)
        }
        lastTimestamp = link.timestamp
        frames += 1

        let elapsed = link.timestamp - windowStart
        guard elapsed >= 1 else { return }
        framesPerSecond = Int((Double(frames) / elapsed).rounded())
        layoutsPerSecond = Int((Double(layouts) / elapsed).rounded())
        worstFrame = slowest * 1000
        frames = 0
        layouts = 0
        slowest = 0
        windowStart = link.timestamp
    }

    // MARK: - Memoria

    /// Lo que la app gasta de verdad: la cifra con la que iOS decide a quién
    /// cerrar (`phys_footprint`), no la memoria residente.
    static var footprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Cuánto le queda a la app antes de que iOS la cierre por memoria.
    static var available: UInt64 {
        UInt64(os_proc_available_memory())
    }

    static func megabytes(_ bytes: UInt64) -> String {
        "\(bytes / 1_048_576) MB"
    }
}
