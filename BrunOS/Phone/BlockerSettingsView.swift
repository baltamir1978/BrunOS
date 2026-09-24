import SwiftUI

/// El bloqueador, editable desde el iPhone: las mismas cosas que en los ajustes
/// del navegador del monitor, para cuando no hay monitor delante.
struct BlockerSettingsView: View {

    private let blocker = AppServices.shared.blocker
    private let notices = AppServices.shared.cookieNotices

    @State private var newDomain = ""
    @State private var newSite = ""
    @State private var newRule = ""
    @State private var newList = ""

    var body: some View {
        List {
            Section {
                Toggle("Esconder los huecos de lo bloqueado", isOn: Binding(
                    get: { blocker.collapsesBlocked },
                    set: { blocker.collapsesBlocked = $0 }
                ))
                HStack {
                    Text(blocker.statusLine)
                        .font(.brunosSans(13))
                        .foregroundStyle(Color.brunosTextSecondary)
                    Spacer()
                    Button("Actualizar ahora") { blocker.updateNow() }
                        .disabled(blocker.activity != nil)
                }
            } footer: {
                Text("Las listas de uBlock Origin, con las mismas direcciones. Se bajan en el iPhone "
                     + "y se renuevan cada 4 días. De cada una entra lo que WebKit sabe hacer: "
                     + "bloquear peticiones y ocultar elementos.")
            }

            Section {
                Toggle("Quitar los avisos de cookies", isOn: Binding(
                    get: { notices.isEnabled },
                    set: { notices.isEnabled = $0 }
                ))
                HStack {
                    Text(notices.statusLine)
                        .font(.brunosSans(13))
                        .foregroundStyle(Color.brunosTextSecondary)
                    Spacer()
                    Button("Actualizar") { notices.updateNow() }
                        .disabled(notices.isUpdating)
                }
                ForEach(notices.exceptions.sorted(), id: \.self) { host in
                    Text(host).font(.brunosMono(14))
                }
                .onDelete { offsets in
                    let sorted = notices.exceptions.sorted()
                    offsets.map { sorted[$0] }.forEach(notices.toggleException(for:))
                }
            } header: {
                Text("Avisos de cookies")
            } footer: {
                Text("Con las reglas de «I Still Don't Care About Cookies». La galleta de la barra "
                     + "del navegador lo apaga en un sitio; esos sitios salen aquí.")
            }

            ForEach(FilterList.Group.allCases.filter { $0 != .custom }, id: \.self) { group in
                Section(group.title) {
                    ForEach(blocker.catalog.filter { $0.group == group }) { list in
                        listToggle(list)
                    }
                }
            }

            Section {
                ForEach(blocker.catalog.filter { $0.group == .custom }) { list in
                    listToggle(list)
                }
                .onDelete { offsets in
                    let custom = blocker.catalog.filter { $0.group == .custom }
                    offsets.map { custom[$0] }.forEach(blocker.removeCustomList)
                }
                addField("https://…/lista.txt", text: $newList) {
                    blocker.addCustomList($0)
                }
            } header: {
                Text(FilterList.Group.custom.title)
            } footer: {
                Text("Cualquier lista con la sintaxis de AdBlock, uBlock o AdGuard, o un fichero hosts. "
                     + "Desliza a la izquierda para quitar una.")
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

    private func listToggle(_ list: FilterList) -> some View {
        Toggle(isOn: Binding(
            get: { blocker.isListEnabled(list) },
            set: { blocker.setList(list, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(list.title)
                if let summary = blocker.summary(of: list) {
                    Text(summary)
                        .font(.brunosMono(12))
                        .foregroundStyle(Color.brunosTextSecondary)
                }
            }
        }
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
