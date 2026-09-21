import SwiftUI

/// Ajustes de BrunOS.
///
/// Los de pantalla sólo tienen sentido con un monitor enchufado, porque lo que
/// se guarda es el perfil **de esa pantalla concreta**, identificada por su
/// resolución nativa. Sin monitor, esa sección se rotula como no disponible en
/// vez de guardar ajustes que no se sabe a quién pertenecen.
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    private let services = AppServices.shared

    @State private var pointer = PointerSettings.load()
    @State private var scale: DisplayProfile.Scale = .x2
    @State private var overscan: DisplayProfile.Overscan = .none

    var body: some View {
        NavigationStack {
            Form {
                displaySection
                mouseSection
                assistiveTouchSection
                aboutSection
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
            }
            .onAppear(perform: loadProfile)
        }
        .tint(.brunosAccent)
    }

    private func loadProfile() {
        guard let profile = services.externalDisplay.currentProfile else { return }
        scale = profile.scale
        overscan = profile.overscan
    }

    // MARK: - Pantalla

    @ViewBuilder
    private var displaySection: some View {
        Section("Pantalla") {
            if let profile = services.externalDisplay.currentProfile {
                LabeledContent("Resolución lógica", value: profile.summary)
                    .font(.brunosMono(14))

                Picker("Escala", selection: $scale) {
                    ForEach(DisplayProfile.Scale.allCases, id: \.self) { value in
                        Text(value.label).tag(value)
                    }
                }
                .onChange(of: scale) { _, newValue in
                    services.externalDisplay.setScale(newValue)
                }

                Picker("Overscan", selection: $overscan) {
                    ForEach(DisplayProfile.Overscan.allCases, id: \.self) { value in
                        Text(value.label).tag(value)
                    }
                }
                .onChange(of: overscan) { _, newValue in
                    services.externalDisplay.setOverscan(newValue)
                }
            } else {
                Text("Sin pantalla externa conectada")
                    .foregroundStyle(Color.brunosTextSecondary)
            }
        }

        // El monitor lo tiene delante Bruno, no quien programa. Enseñar aquí lo
        // que el sistema dice en crudo ahorra tener que pescarlo del log con el
        // Mac conectado, y fue lo que destapó que `nativeBounds` no describe el
        // modo de vídeo de una pantalla externa.
        if let screen = services.externalDisplay.currentScreen {
            Section("Diagnóstico de la pantalla") {
                ForEach(ExternalDisplayManager.diagnostics(for: screen), id: \.0) { item in
                    LabeledContent(item.0, value: item.1)
                        .font(.brunosMono(13))
                }
            }
        }
    }

    // MARK: - Ratón

    private var mouseSection: some View {
        Section {
            LabeledContent("Fuente activa", value: services.mouse.activeSourceName)
                .font(.brunosMono(14))

            // Distingue "el ratón no llega a la app" de "llega pero el cursor
            // no se mueve". Se parecen mucho vistos desde el sofá y se
            // arreglan de forma muy distinta.
            LabeledContent(
                "AssistiveTouch",
                value: services.assistiveTouch.isRunning ? "activo" : "INACTIVO"
            )
            .font(.brunosMono(14))

            LabeledContent(
                "GCMouse ve un ratón",
                value: services.assistiveTouch.hasMouse ? "sí" : "no"
            )
            .font(.brunosMono(14))

            LabeledContent(
                "Eventos recibidos",
                value: "GCMouse \(services.mouse.gcEventCount) · indirecto \(services.mouse.indirectEventCount)"
            )
            .font(.brunosMono(13))

            VStack(alignment: .leading) {
                Text("Sensibilidad: \(pointer.sensitivity, format: .number.precision(.fractionLength(1)))×")
                    .font(.brunosSans(14))
                Slider(value: $pointer.sensitivity, in: 0.4...3, step: 0.1)
                    .accessibilityLabel("Sensibilidad del puntero")
            }

            VStack(alignment: .leading) {
                Text("Velocidad del scroll: \(pointer.scrollSpeed, format: .number.precision(.fractionLength(1)))×")
                    .font(.brunosSans(14))
                Slider(value: $pointer.scrollSpeed, in: 0.4...3, step: 0.1)
                    .accessibilityLabel("Velocidad del scroll")
            }

            Toggle("Aceleración", isOn: $pointer.acceleration)

            Toggle("Scroll natural", isOn: $pointer.naturalScrolling)
        } header: {
            Text("Ratón")
        } footer: {
            Text("Con la aceleración puesta, un movimiento lento va casi 1:1 para poder "
                 + "apuntar fino, y uno rápido se multiplica para cruzar la pantalla de un "
                 + "manotazo. **Conviene dejarla puesta**: el recorrido disponible es la "
                 + "pantalla del iPhone, y cuando el puntero llega a su borde el cursor se "
                 + "planta.\n\nConviene también subir la velocidad de seguimiento en Ajustes "
                 + "de iOS › Accesibilidad › Control del puntero, porque **se multiplica con la "
                 + "de aquí**. Si el cursor da saltos, baja ésta antes que aquélla.")
        }
        .onChange(of: pointer) { _, newValue in
            newValue.save()
            services.pointer.settings = newValue
        }
    }

    // MARK: - AssistiveTouch

    private var assistiveTouchSection: some View {
        Section("AssistiveTouch") {
            LabeledContent(
                "Estado",
                value: services.assistiveTouch.isRunning ? "activo" : "inactivo"
            )
            .font(.brunosMono(14))

            NavigationLink("Asistente de configuración") {
                AssistiveTouchGuideView()
            }
        }
    }

    // MARK: - Acerca de

    private var aboutSection: some View {
        Section("Acerca de") {
            LabeledContent("Versión", value: Self.versionString)
                .font(.brunosMono(14))
            LabeledContent("Fase", value: "1 · escritorio y entrada")
                .font(.brunosMono(14))
            Link("Código en GitHub", destination: URL(string: "https://github.com/baltamir1978/BrunOS")!)
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

#Preview {
    SettingsView()
}
