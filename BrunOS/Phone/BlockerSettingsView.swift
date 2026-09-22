import SwiftUI

/// El bloqueador, editable desde el iPhone: las mismas cosas que en los ajustes
/// del navegador del monitor, para cuando no hay monitor delante.
struct BlockerSettingsView: View {

    private let blocker = AppServices.shared.blocker

    @State private var newDomain = ""
    @State private var newSite = ""
    @State private var newRule = ""

    var body: some View {
        List {
            Section {
                ForEach(blocker.sources) { source in
                    Toggle(isOn: Binding(
                        get: { blocker.isSourceEnabled(source) },
                        set: { blocker.setSource(source, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.label)
                            Text("\(source.ruleCount.formatted()) reglas")
                                .font(.brunosMono(12))
                                .foregroundStyle(Color.brunosTextSecondary)
                        }
                    }
                }
                if blocker.sources.isEmpty {
                    Text("No hay listas cargadas")
                        .foregroundStyle(Color.brunosTextSecondary)
                }
            } header: {
                Text("Listas")
            } footer: {
                Text("Se descargan y convierten con Tools/fetch-blocklists.sh en el Mac.")
            }

            Section {
                ForEach(blocker.blockedDomains, id: \.self) { domain in
                    Text(domain).font(.brunosMono(14))
                }
                .onDelete { offsets in
                    offsets.map { blocker.blockedDomains[$0] }.forEach(blocker.removeBlockedDomain)
                }
                addField("ejemplo.com", text: $newDomain) {
                    blocker.addBlockedDomain($0)
                }
            } header: {
                Text("Dominios bloqueados")
            } footer: {
                Text("Se bloquea el dominio y todos sus subdominios, en cualquier web. "
                     + "Desliza a la izquierda para quitar uno.")
            }

            Section {
                ForEach(blocker.exceptions.sorted(), id: \.self) { host in
                    Text(host).font(.brunosMono(14))
                }
                .onDelete { offsets in
                    let sorted = blocker.exceptions.sorted()
                    offsets.map { sorted[$0] }.forEach(blocker.toggleException(for:))
                }
                addField("ejemplo.com", text: $newSite) {
                    blocker.toggleException(for: $0)
                }
            } header: {
                Text("Sitios sin bloqueo")
            } footer: {
                Text("Para las webs que se rompen con el bloqueador.")
            }

            Section {
                ForEach(blocker.hideRules, id: \.self) { rule in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.selector).font(.brunosMono(14))
                        Text(rule.domain ?? "todas las webs")
                            .font(.brunosSans(12))
                            .foregroundStyle(Color.brunosTextSecondary)
                    }
                }
                .onDelete { offsets in
                    offsets.map { blocker.hideRules[$0] }.forEach(blocker.removeHideRule)
                }
                addField("ejemplo.com##.banner", text: $newRule) { text in
                    if let rule = ContentBlocker.HideRule.parse(text) { blocker.addHideRule(rule) }
                }
            } header: {
                Text("Elementos ocultos")
            } footer: {
                Text("Con la sintaxis de AdBlock: «ejemplo.com##.banner» oculta lo que tenga la "
                     + "clase banner sólo en ejemplo.com; «##.banner», en todas.")
            }

            if let error = blocker.lastError {
                Section {
                    Text(error)
                        .font(.brunosSans(13))
                        .foregroundStyle(Color.brunosAccent)
                }
            }
        }
        .navigationTitle("Bloqueo de anuncios")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Un campo con botón de añadir al final de cada lista.
    private func addField(
        _ placeholder: String,
        text: Binding<String>,
        add: @escaping (String) -> Void
    ) -> some View {
        HStack {
            TextField(placeholder, text: text)
                .font(.brunosMono(14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit { commit(text, add) }
            Button("Añadir") { commit(text, add) }
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func commit(_ text: Binding<String>, _ add: (String) -> Void) {
        let value = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        add(value)
        text.wrappedValue = ""
    }
}
