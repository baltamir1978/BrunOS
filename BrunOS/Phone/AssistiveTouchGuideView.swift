import SwiftUI

/// Asistente para dejar AssistiveTouch configurado de una vez por todas.
///
/// **Por qué es un asistente y no un botón.** iOS no deja que una app active
/// AssistiveTouch, ni que cree automatizaciones de Atajos, ni que las importe.
/// Lo único que sí puede es *ejecutar* un atajo que ya exista. Así que los pasos
/// los da Bruno una vez, guiado, y a partir de ahí BrunOS se apaña solo.
///
/// **Esta pantalla tiene que bastarse sola.** La primera versión se limitaba a
/// decir "crea un atajo con la acción tal", y desde fuera parecía que el botón
/// «Activar» estuviera roto: no se entendía que hubiera que crear nada. Si hace
/// falta que alguien te explique por qué un botón no hace nada, el fallo es de
/// la app. De ahí la explicación del principio, los pasos detallados y la
/// sección de problemas del final.
///
/// Las casillas las marca él, porque **BrunOS no puede comprobar** si una
/// automatización existe. Lo único observable es si AssistiveTouch está activo.
struct AssistiveTouchGuideView: View {

    private let services = AppServices.shared
    @State private var steps: [AssistiveTouchStep: Bool] = [:]
    @State private var shortcutName = AppServices.shared.assistiveTouch.shortcutName
    @State private var sharedLink = ""
    @State private var linkFailed = false

    var body: some View {
        List {
            statusSection
            explanationSection
            ForEach(Array(AssistiveTouchStep.allCases.enumerated()), id: \.element) { index, step in
                stepSection(number: index + 1, step: step)
            }
            quickWaySection
            toolsSection
            troubleshootingSection
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
            HStack(spacing: 10) {
                Circle()
                    .fill(services.assistiveTouch.isRunning ? Color.brunosAccentAlt : Color.brunosAccent)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(services.assistiveTouch.isRunning ? "Activo" : "Inactivo")
                        .font(.brunosSans(16, weight: .semibold))
                    Text(isConfigured
                         ? "Configurado: se encenderá solo al abrir BrunOS."
                         : "Sigue los pasos de abajo una vez.")
                        .font(.brunosSans(12))
                        .foregroundStyle(Color.brunosTextSecondary)
                }
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Estado")
        }
    }

    // MARK: - Por qué hace falta

    private var explanationSection: some View {
        Section("Por qué hay que hacer esto") {
            VStack(alignment: .leading, spacing: 10) {
                Text("En el iPhone, **un ratón sólo funciona con AssistiveTouch encendido**. "
                     + "Da igual que sea Bluetooth o USB: sin él, iOS ignora el ratón por completo.")
                Text("Sí existe una API oficial para encenderlo, y BrunOS la intenta primero. "
                     + "Pero Apple **sólo se la concede a apps bloqueadas en modo de app única "
                     + "por un perfil de gestión de dispositivos**, pensado para quioscos. En un "
                     + "iPhone normal falla, y entonces BrunOS recurre a ejecutar un atajo tuyo, "
                     + "que es lo único que sí puede hacer cualquier app.")
                Text("Por eso el botón «Activar» no crea nada: sólo lanza el atajo. Si todavía no "
                     + "lo has creado, abrirá Atajos y volverá sin hacer nada. Eso es justo lo "
                     + "que arreglan los pasos de abajo.")
                Text("Se hace **una sola vez**. Después, AssistiveTouch se enciende y se apaga "
                     + "solo al abrir y cerrar BrunOS.")
                    .foregroundStyle(Color.brunosTextSecondary)
            }
            .font(.brunosSans(14))
            .padding(.vertical, 2)
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

            Text(step.purpose)
                .font(.brunosSans(13))
                .foregroundStyle(Color.brunosTextSecondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(step.instructions.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.brunosMono(13, bold: true))
                            .foregroundStyle(Color.brunosAccent)
                        Text(line)
                            .font(.brunosSans(14))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Paso \(index + 1). \(line)")
                }
            }
            .padding(.vertical, 2)

            if step == .createShortcut {
                shortcutNameField
                sharedLinkField
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

    private var shortcutNameField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nombre del atajo")
                .font(.brunosSans(12))
                .foregroundStyle(Color.brunosTextSecondary)
            TextField("Nombre del atajo", text: $shortcutName)
                .font(.brunosMono(14))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                // Guardar al escribir, no al pulsar intro: si no, se cambia el
                // nombre, se toca «Probar» y sigue buscando el anterior.
                .onChange(of: shortcutName) { _, newValue in
                    services.assistiveTouch.shortcutName = newValue
                }
            Text("Tiene que coincidir **carácter por carácter** con el del atajo, "
                 + "mayúsculas incluidas.")
                .font(.brunosSans(12))
                .foregroundStyle(Color.brunosTextSecondary)
        }
    }

    private var sharedLinkField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("¿Tienes ya el atajo compartido por iCloud?")
                .font(.brunosSans(12))
                .foregroundStyle(Color.brunosTextSecondary)
            TextField("Pega aquí el enlace de iCloud", text: $sharedLink)
                .font(.brunosMono(12))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !sharedLink.isEmpty {
                Button("Añadir atajo") {
                    linkFailed = false
                    services.assistiveTouch.open(URL(string: sharedLink)) {
                        linkFailed = true
                    }
                }
            }
            if linkFailed {
                Text("No se pudo abrir ese enlace.")
                    .font(.brunosSans(12))
                    .foregroundStyle(Color.brunosAccent)
            }
        }
    }

    // MARK: - La vía rápida

    /// La función rápida de accesibilidad: triple clic en el botón lateral.
    ///
    /// Va la primera de las alternativas porque **es la más sencilla con
    /// diferencia** y no depende de Atajos para nada. No se automatiza sola,
    /// pero se activa en un segundo desde cualquier sitio.
    private var quickWaySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Si no quieres pelearte con Atajos, iOS trae un atajo de teclas físico "
                     + "que enciende y apaga AssistiveTouch al instante.")
                    .font(.brunosSans(14))

                VStack(alignment: .leading, spacing: 6) {
                    instruction(1, "Ve a Ajustes de iOS › Accesibilidad › Función rápida.")
                    instruction(2, "Marca «AssistiveTouch».")
                    instruction(3, "A partir de ahora, **tres clics seguidos en el botón lateral** "
                                + "lo encienden y lo apagan.")
                }

                Text("No se automatiza al abrir BrunOS, pero se hace en un segundo y funciona "
                     + "desde cualquier app.")
                    .font(.brunosSans(12))
                    .foregroundStyle(Color.brunosTextSecondary)
            }
            .padding(.vertical, 2)
        } header: {
            Text("La vía rápida, sin Atajos")
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.brunosMono(13, bold: true))
                .foregroundStyle(Color.brunosAccent)
            Text(text)
                .font(.brunosSans(14))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Comprobar

    private var toolsSection: some View {
        Section {
            Button("Abrir Atajos") {
                services.assistiveTouch.open(AssistiveTouchMonitor.shortcutsAppURL) {}
            }

            Button("Probar ahora") {
                services.assistiveTouch.enable()
            }
            .font(.brunosSans(16, weight: .semibold))

            if let attempt = services.assistiveTouch.lastAttempt {
                Text(attempt.message)
                    .font(.brunosSans(13))
                    .foregroundStyle(attempt.isGood ? Color.brunosAccentAlt : Color.brunosAccent)
            }

            LabeledContent("Buscando el atajo", value: "«\(services.assistiveTouch.shortcutName)»")
                .font(.brunosMono(12))
        } header: {
            Text("Comprobar")
        } footer: {
            Text("«Probar ahora» ejecuta el atajo y vuelve aquí. Si el estado de arriba "
                 + "cambia a Activo, está bien configurado.")
        }
    }

    // MARK: - Si algo falla

    private var troubleshootingSection: some View {
        Section("Si algo falla") {
            VStack(alignment: .leading, spacing: 12) {
                problem(
                    "«Atajos no pudo ejecutarlo»",
                    solution: "No hay ningún atajo con ese nombre. Cotéjalo con el que aparece "
                        + "arriba en «Buscando el atajo»."
                )
                problem(
                    "«El atajo se ejecutó, pero AssistiveTouch sigue apagado»",
                    solution: "El atajo existe pero su acción no es la correcta. Ábrelo en Atajos "
                        + "y comprueba que sea «Establecer AssistiveTouch» puesta en «activar»."
                )
                problem(
                    "Se activa, pero el ratón no mueve nada",
                    solution: "Mira si aparece el círculo gris de AssistiveTouch en el iPhone y si "
                        + "se mueve al mover el ratón. Si no se mueve, iOS no está viendo el ratón "
                        + "y no es cosa de BrunOS. En Ajustes › Ratón puedes ver si llegan eventos."
                )
                problem(
                    "Quiero que BrunOS lo encienda solo, sin atajos ni tríos de clics",
                    solution: "Se puede, pero hace falta que el iPhone esté supervisado con "
                        + "Apple Configurator y BrunOS autorizada por un perfil de app única. "
                        + "Eso obliga a borrar y reconfigurar el teléfono, así que para un "
                        + "iPhone personal casi nunca compensa. Si algún día lo haces, BrunOS "
                        + "lo detecta solo y deja de pedirte nada."
                )
                problem(
                    "El cursor va a tirones o demasiado rápido",
                    solution: "Sube la velocidad en Ajustes de iOS › Accesibilidad › Control del "
                        + "puntero y baja la sensibilidad en Ajustes › Ratón. Las dos se "
                        + "multiplican entre sí."
                )
            }
            .padding(.vertical, 2)
        }
    }

    private func problem(_ symptom: String, solution: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(symptom)
                .font(.brunosSans(14, weight: .semibold))
                .foregroundStyle(Color.brunosText)
            Text(solution)
                .font(.brunosSans(13))
                .foregroundStyle(Color.brunosTextSecondary)
        }
        .accessibilityElement(children: .combine)
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
                .lineLimit(1)
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
