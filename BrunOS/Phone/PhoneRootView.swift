import SwiftUI

/// Interfaz del iPhone cuando hace de mando.
///
/// Se deja que SwiftUI aplique Liquid Glass por defecto y sólo se tiñe con los
/// colores de BrunOS: nada de reconstruir los materiales a mano.
struct PhoneRootView: View {

    @State private var dictation = DictationController()
    @State private var showingSettings = false
    @State private var isDimmed = false

    private let services = AppServices.shared

    /// El iPhone hace de mando: hay monitor delante y se mira allí, no aquí.
    private var isRemoteMode: Bool {
        services.externalDisplay.currentProfile != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.brunosBackground.ignoresSafeArea()

                // Con monitor conectado, **toda la pantalla del iPhone es
                // trackpad**, y lo demás va encima.
                //
                // No es un capricho de diseño, resuelve un problema concreto:
                // con AssistiveTouch, el botón izquierdo del ratón no llega a
                // la app como evento de ratón, sino que el sistema lo convierte
                // en un toque donde esté el puntero. Sólo el derecho llega como
                // botón. Si el trackpad no ocupa todo, hacer clic izquierdo
                // fuera de él no hace nada, que es justo lo que pasaba.
                if isRemoteMode {
                    TrackpadView(isFullScreen: true)
                        .ignoresSafeArea()
                        .accessibilityLabel("Trackpad")
                }

                VStack(spacing: 16) {
                    header
                    if services.assistiveTouch.shouldWarn {
                        AssistiveTouchBanner()
                    }
                    if isRemoteMode {
                        Spacer(minLength: 0)
                    } else {
                        TrackpadView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("Trackpad")
                    }
                    buttons
                }
                .padding(16)
                // En modo mando la cabecera y los botones flotan sobre el
                // trackpad, así que no pueden tragarse los toques que no caigan
                // justo encima de ellos.
                .allowsHitTesting(true)

                if isDimmed {
                    dimOverlay
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ajustes", systemImage: "gearshape") {
                        showingSettings = true
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .brunosShowSettings)) { _ in
                showingSettings = true
            }
        }
        .tint(.brunosAccent)
    }

    // MARK: - Cabecera

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Text("brunOS").foregroundStyle(Color.brunosText)
                Text("_").foregroundStyle(Color.brunosAccent)
            }
            .font(.brunosMono(28, bold: true))
            .accessibilityLabel("BrunOS")

            HStack(spacing: 14) {
                statusChip(
                    "display",
                    label: services.externalDisplay.currentProfile?.summary ?? "sin pantalla",
                    active: services.externalDisplay.currentProfile != nil
                )
                statusChip(
                    "ratón",
                    label: services.assistiveTouch.hasMouse ? "conectado" : "sin ratón",
                    active: services.assistiveTouch.hasMouse
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusChip(_ name: String, label: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color.brunosAccentAlt : Color.brunosTextSecondary)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.brunosMono(12))
                .foregroundStyle(Color.brunosTextSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(label)")
    }

    // MARK: - Botones

    private var buttons: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                actionButton("Teclado", icon: "keyboard") {
                    // El teclado en pantalla aparece al hacerse first responder
                    // el campo oculto que escribe hacia el panel con foco.
                    NotificationCenter.default.post(name: .brunosShowKeyboard, object: nil)
                }
                actionButton(
                    dictation.isActive ? "Escuchando" : "Dictado",
                    icon: "mic",
                    highlighted: dictation.isActive
                ) {
                    dictation.toggle()
                }
            }
            GridRow {
                actionButton("Traer ventana", icon: "rectangle.on.rectangle") {
                    // Llega en la Fase 3: es la vía de escape para las páginas
                    // que no aceptan clics sintéticos.
                }
                .disabled(true)

                actionButton("Atenuar", icon: "moon", highlighted: isDimmed) {
                    isDimmed.toggle()
                }
            }
        }
    }

    private func actionButton(
        _ title: String,
        icon: String,
        highlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                Text(title)
                    .font(.brunosSans(13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 66)
        }
        .buttonStyle(.glass)
        .tint(highlighted ? Color.brunosAccent : Color.brunosText)
        .accessibilityLabel(title)
    }

    /// "Atenuar" apaga la pantalla del iPhone a ojo, sin bloquearla: la app
    /// tiene que seguir en primer plano o iOS vuelve a duplicar la pantalla.
    private var dimOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .onTapGesture { isDimmed = false }
            .accessibilityLabel("Pantalla atenuada. Toca para volver.")
            .accessibilityAddTraits(.isButton)
    }
}

extension Notification.Name {
    static let brunosShowKeyboard = Notification.Name("BrunOSShowKeyboard")
    /// La pide el icono de ajustes del dock, desde la pantalla externa.
    static let brunosShowSettings = Notification.Name("BrunOSShowSettings")
    /// Cambió el zoom del navegador desde los ajustes.
    static let brunosBrowserZoomChanged = Notification.Name("BrunOSBrowserZoomChanged")
}

/// Aviso de que el ratón no va a funcionar hasta activar AssistiveTouch.
///
/// Aparece sólo cuando hace falta de verdad: con monitor o ratón conectado y
/// AssistiveTouch apagado.
struct AssistiveTouchBanner: View {

    private let services = AppServices.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("El ratón necesita AssistiveTouch")
                .font(.brunosSans(15, weight: .semibold))
                .foregroundStyle(Color.brunosText)
            Text("En el iPhone, un ratón Bluetooth sólo funciona con AssistiveTouch "
                 + "encendido, y ninguna app puede encenderlo por su cuenta.")
                .font(.brunosSans(13))
                .foregroundStyle(Color.brunosTextSecondary)

            HStack {
                Button("Activar") {
                    services.assistiveTouch.enable()
                }
                .buttonStyle(.glassProminent)
                .tint(Color.brunosAccent)

                NavigationLink("Configurar") {
                    AssistiveTouchGuideView()
                }
                .font(.brunosSans(14))
            }

            // Sin esto, «Activar» abría Atajos, volvía y no pasaba nada
            // visible: imposible saber si el atajo no existía o si existía y
            // no hacía su trabajo.
            if let attempt = services.assistiveTouch.lastAttempt {
                Text(attempt.message)
                    .font(.brunosSans(12))
                    .foregroundStyle(attempt.isGood ? Color.brunosAccentAlt : Color.brunosAccent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brunosPanelElevated, in: .rect(cornerRadius: Tokens.Metric.paneCornerRadius))
    }
}

#Preview {
    PhoneRootView()
}
