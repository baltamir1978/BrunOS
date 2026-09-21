import SwiftUI

/// Asistente para dejar AssistiveTouch configurado de una vez por todas.
///
/// **Por qué es un asistente y no un botón.** iOS no deja que una app active
/// AssistiveTouch, ni que cree automatizaciones de Atajos, ni que las importe.
/// Lo único que sí puede es *ejecutar* un atajo que ya exista. Así que los pasos
/// los da Bruno una vez, guiado, y a partir de ahí BrunOS se apaña solo.
///
/// Las casillas las marca él, porque **BrunOS no puede comprobar** si una
/// automatización existe. Lo único observable es si AssistiveTouch está activo,
/// y eso es lo que se rotula arriba del todo.
struct AssistiveTouchGuideView: View {

    private let services = AppServices.shared
    @State private var steps: [AssistiveTouchStep: Bool] = [:]
    @State private var shortcutName = AppServices.shared.assistiveTouch.shortcutName
    @State private var sharedLink = ""
    @State private var testResult: String?

    var body: some View {
        List {
            statusSection
            ForEach(Array(AssistiveTouchStep.allCases.enumerated()), id: \.element) { index, step in
                stepSection(number: index + 1, step: step)
            }
            toolsSection
        }
        .navigationTitle("AssistiveTouch")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            for step in AssistiveTouchStep.allCases {
                steps[step] = step.isDone
            }
            services.assistiveTouch.refresh()
        }
    }

    // MARK: - Estado

    private var isConfigured: Bool {
        services.assistiveTouch.isRunning
            && AssistiveTouchStep.allCases.allSatisfy { steps[$0] == true }
    }

    private var statusSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(services.assistiveTouch.isRunning ? Color.brunosAccentAlt : Color.brunosAccent)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(services.assistiveTouch.isRunning ? "Activo" : "Inactivo")
                        .font(.brunosSans(16, weight: .semibold))
                    if isConfigured {
                        Text("Configurado")
                            .font(.brunosSans(12))
                            .foregroundStyle(Color.brunosTextSecondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Estado")
        } footer: {
            Text("Un ratón Bluetooth en el iPhone sólo funciona con AssistiveTouch "
                 + "encendido. Ninguna app puede encenderlo por API, así que hay que "
                 + "dejarlo automatizado una vez.")
        }
    }

    // MARK: - Pasos

    @ViewBuilder
    private func stepSection(number: Int, step: AssistiveTouchStep) -> some View {
        Section {
            AssistiveTouchIllustration(step: step)
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.brunosPanel)

            Text(step.detail)
                .font(.brunosSans(14))

            if step == .createShortcut {
                TextField("Nombre del atajo", text: $shortcutName)
                    .font(.brunosMono(14))
                    .autocorrectionDisabled()
                    // Guardar al escribir, no al pulsar intro: si no, se cambia
                    // el nombre, se toca «Probar» y sigue buscando el anterior.
                    .onChange(of: shortcutName) { _, newValue in
                        services.assistiveTouch.shortcutName = newValue
                    }

                TextField("Enlace de iCloud a un atajo compartido (opcional)", text: $sharedLink)
                    .font(.brunosMono(12))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if !sharedLink.isEmpty {
                    Button("Añadir atajo") {
                        services.assistiveTouch.open(URL(string: sharedLink)) {
                            testResult = "No se pudo abrir el enlace."
                        }
                    }
                }
            }

            Toggle("Hecho", isOn: Binding(
                get: { steps[step] ?? false },
                set: { newValue in
                    steps[step] = newValue
                    step.isDone = newValue
                }
            ))
            .font(.brunosSans(14, weight: .medium))
        } header: {
            Text("Paso \(number) · \(step.title)")
        }
    }

    // MARK: - Herramientas

    private var toolsSection: some View {
        Section {
            Button("Abrir Atajos") {
                services.assistiveTouch.open(AssistiveTouchMonitor.shortcutsAppURL) {
                    testResult = "No se pudo abrir Atajos."
                }
            }

            Button("Probar") {
                testResult = nil
                services.assistiveTouch.runShortcut()
            }

            if let attempt = services.assistiveTouch.lastAttempt {
                Text(attempt.message)
                    .font(.brunosSans(13))
                    .foregroundStyle(attempt.isGood ? Color.brunosAccentAlt : Color.brunosAccent)
            }

            if let testResult {
                Text(testResult)
                    .font(.brunosSans(13))
                    .foregroundStyle(Color.brunosAccent)
            }

            // El nombre tiene que coincidir carácter por carácter con el del
            // atajo. Enseñarlo entero evita perseguir un espacio de más.
            LabeledContent("Buscando el atajo", value: "«\(services.assistiveTouch.shortcutName)»")
                .font(.brunosMono(12))
        } footer: {
            Text("«Probar» ejecuta el atajo y vuelve aquí. Si al volver el estado de "
                 + "arriba cambia a Activo, está bien configurado.")
        }
    }
}

/// Ilustraciones sencillas de cada paso.
///
/// Se dibujan con formas, **no son capturas del sistema**: una captura de
/// Atajos envejece con cada versión de iOS y además no se puede redistribuir.
struct AssistiveTouchIllustration: View {

    let step: AssistiveTouchStep

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.brunosBorder, lineWidth: 1)

            switch step {
            case .createShortcut:
                shortcutCard
            case .automationOnOpen:
                automationCard(trigger: "Se abre", value: "activado")
            case .automationOnClose:
                automationCard(trigger: "Se cierra", value: "desactivado")
            }
        }
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }

    private var shortcutCard: some View {
        VStack(spacing: 6) {
            Text(AppServices.shared.assistiveTouch.shortcutName)
                .font(.brunosMono(11, bold: true))
                .foregroundStyle(Color.brunosAccent)
            actionRow("Establecer AssistiveTouch", value: "activar")
        }
        .padding(.horizontal, 16)
    }

    private func automationCard(trigger: String, value: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "app.badge")
                Text("BrunOS · \(trigger)")
            }
            .font(.brunosMono(11, bold: true))
            .foregroundStyle(Color.brunosAccent)

            actionRow("Establecer AssistiveTouch", value: value)

            Text("Ejecutar inmediatamente")
                .font(.brunosMono(10))
                .foregroundStyle(Color.brunosTextSecondary)
        }
        .padding(.horizontal, 16)
    }

    private func actionRow(_ title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.brunosMono(10))
                .foregroundStyle(Color.brunosText)
            Text(value)
                .font(.brunosMono(10, bold: true))
                .foregroundStyle(Color.brunosBackground)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.brunosAccentAlt, in: .capsule)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.brunosPanelElevated, in: .rect(cornerRadius: 6))
    }
}

#Preview {
    NavigationStack {
        AssistiveTouchGuideView()
    }
}
