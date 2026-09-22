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
    @State private var browserZoom = BrowserZoom.default
    @State private var scale: DisplayProfile.Scale = .x2
    @State private var overscan: DisplayProfile.Overscan = .none
    @State private var appearance = DesktopTheme.appearance
    @State private var searchEngine = SearchEngine.current

    var body: some View {
        NavigationStack {
            Form {
                displaySection
                hostsSection
                browserSection
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
            // El puntero moviéndose por los ajustes es prueba de que
            // AssistiveTouch funciona, aunque iOS diga lo contrario: sin esto,
            // abriendo los ajustes nada más arrancar salía «no detectado».
            .onContinuousHover { _ in
                services.assistiveTouch.isPointerWorking = true
            }
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

                NavigationLink {
                    WallpaperPicker()
                } label: {
                    LabeledContent("Fondo", value: services.wallpaper.current.label)
                        .font(.brunosMono(14))
                }
            }

            // Esto sí vale sin monitor: no depende de la pantalla concreta.
            Picker("Apariencia del escritorio", selection: $appearance) {
                ForEach(DesktopAppearance.allCases, id: \.self) { value in
                    // En el monitor los valores van en minúscula, como «sí» y
                    // «no»; en una lista de iOS, con mayúscula.
                    Text(value.label.prefix(1).uppercased() + value.label.dropFirst()).tag(value)
                }
            }
            .onChange(of: appearance) { _, newValue in
                DesktopTheme.appearance = newValue
            }

            if services.externalDisplay.currentProfile == nil {
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

    // MARK: - Hosts

    private var hostsSection: some View {
        Section("SSH") {
            NavigationLink {
                HostsView()
            } label: {
                LabeledContent(
                    "Hosts",
                    value: services.hosts.hosts.isEmpty
                        ? "ninguno"
                        : "\(services.hosts.hosts.count)"
                )
                .font(.brunosMono(14))
            }

            NavigationLink {
                KnownHostsView()
            } label: {
                LabeledContent("Claves conocidas") {
                    if services.knownHosts.pendingChanges.isEmpty {
                        Text("\(services.knownHosts.entries.count)")
                    } else {
                        Label("una ha cambiado", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.brunosAccent)
                    }
                }
                .font(.brunosMono(14))
            }

            LabeledContent(
                "Tailscale",
                value: services.tailscale.isLikelyUp ? "parece activo" : "no detectado"
            )
            .font(.brunosMono(14))
        }
    }

    // MARK: - Navegador

    private var browserSection: some View {
        Section {
            VStack(alignment: .leading) {
                Text("Zoom de las páginas: \(Int(browserZoom * 100)) %")
                    .font(.brunosSans(14))
                Slider(value: $browserZoom, in: 0.5...2, step: 0.05)
                    .accessibilityLabel("Zoom de las páginas")
            }
            .onChange(of: browserZoom) { _, newValue in
                BrowserZoom.remember(newValue)
                NotificationCenter.default.post(name: .brunosBrowserZoomChanged, object: nil)
            }

            Picker("Buscador", selection: $searchEngine) {
                ForEach(SearchEngine.allCases, id: \.self) { value in
                    Text(value.label).tag(value)
                }
            }
            .onChange(of: searchEngine) { _, newValue in
                SearchEngine.current = newValue
            }

            Toggle("Bloquear anuncios", isOn: Binding(
                get: { services.blocker.isEnabled },
                set: { services.blocker.isEnabled = $0 }
            ))

            NavigationLink {
                BlockerSettingsView()
            } label: {
                LabeledContent(
                    "Listas y reglas",
                    value: services.blocker.isReady
                        ? "\(services.blocker.sources.count) listas"
                        : "sin cargar"
                )
            }

            if let error = services.blocker.lastError {
                Text(error)
                    .font(.brunosSans(12))
                    .foregroundStyle(Color.brunosAccent)
            }
        } header: {
            Text("Navegador")
        } footer: {
            Text("El zoom arranca compensando la escala de la pantalla: el escritorio se "
                 + "maqueta en puntos lógicos y, sin compensar, las páginas salen "
                 + "desproporcionadas frente al resto de la interfaz.\n\n"
                 + "Las listas son EasyList y EasyPrivacy, y **no vienen incluidas**: tienen "
                 + "licencia propia. Se generan con `Tools/fetch-blocklists.sh` en el Mac.\n\n"
                 + "No hay contador de bloqueados: WebKit no dice cuántas peticiones detiene, "
                 + "y enseñar un número inventado sería peor que no enseñar ninguno.")
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
                value: services.assistiveTouch.statusLabel
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

            Picker("Dirección del scroll", selection: $pointer.naturalScrolling) {
                Text("Natural").tag(true)
                Text("Inversa").tag(false)
            }
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
                value: services.assistiveTouch.statusLabel
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
