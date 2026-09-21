import SwiftUI

/// Las claves de servidor que BrunOS ya conoce.
struct KnownHostsView: View {

    private let services = AppServices.shared

    var body: some View {
        List {
            explanation
            changedSection
            knownSection
        }
        .navigationTitle("Claves conocidas")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var explanation: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("El cifrado de SSH impide que nadie escuche por el camino, pero no dice "
                     + "**con quién** estás hablando. Eso lo dice la clave del servidor.")
                Text("La primera vez que te conectas a una máquina, BrunOS guarda su clave. A "
                     + "partir de ahí tiene que coincidir. Si cambia, **no se conecta** y te "
                     + "avisa aquí.")
                Text("Es lo mismo que hace `ssh` de toda la vida con su fichero known_hosts.")
                    .font(.brunosSans(12))
                    .foregroundStyle(Color.brunosTextSecondary)
            }
            .font(.brunosSans(14))
            .padding(.vertical, 2)
        }
    }

    /// Lo que de verdad importa de esta pantalla: una clave que cambió.
    @ViewBuilder
    private var changedSection: some View {
        if !services.knownHosts.pendingChanges.isEmpty {
            Section {
                ForEach(services.knownHosts.pendingChanges.sorted(by: { $0.key < $1.key }), id: \.key) { id, fingerprint in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(id)
                            .font(.brunosMono(15, bold: true))
                            .foregroundStyle(Color.brunosAccent)

                        if let previous = services.knownHosts.entries.first(where: { $0.id == id }) {
                            labelled("Guardada", previous.displayFingerprint)
                        }
                        labelled("Presentada ahora", "SHA256:\(fingerprint)")

                        Text("Si acabas de reinstalar esa máquina, es normal. Si no lo esperabas, "
                             + "**no la aceptes**: alguien podría estar poniéndose en medio.")
                            .font(.brunosSans(13))
                            .foregroundStyle(Color.brunosTextSecondary)

                        Button("Aceptar la clave nueva", role: .destructive) {
                            accept(id: id, fingerprint: fingerprint)
                        }
                        .font(.brunosSans(14, weight: .semibold))
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Label("Una clave ha cambiado", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.brunosAccent)
            }
        }
    }

    private var knownSection: some View {
        Section("Máquinas conocidas") {
            if services.knownHosts.entries.isEmpty {
                Text("Todavía ninguna. Se irán guardando según te conectes.")
                    .font(.brunosSans(14))
                    .foregroundStyle(Color.brunosTextSecondary)
            }

            ForEach(services.knownHosts.entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.id)
                        .font(.brunosMono(15, bold: true))
                    Text(entry.displayFingerprint)
                        .font(.brunosMono(11))
                        .foregroundStyle(Color.brunosTextSecondary)
                        .textSelection(.enabled)
                    Text("Vista por primera vez el \(entry.firstSeen.formatted(date: .abbreviated, time: .shortened))")
                        .font(.brunosSans(11))
                        .foregroundStyle(Color.brunosTextSecondary)
                }
                .accessibilityElement(children: .combine)
            }
            .onDelete { offsets in
                for index in offsets {
                    services.knownHosts.forget(services.knownHosts.entries[index])
                }
            }
        }
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.brunosSans(11))
                .foregroundStyle(Color.brunosTextSecondary)
            Text(value)
                .font(.brunosMono(11))
                .textSelection(.enabled)
        }
    }

    private func accept(id: String, fingerprint: String) {
        // El identificador es `host` o `host:puerto`, como en known_hosts.
        let parts = id.split(separator: ":")
        let host = String(parts[0])
        let port = parts.count > 1 ? Int(parts[1]) ?? 22 : 22
        services.knownHosts.trust(fingerprint: fingerprint, host: host, port: port)
    }
}

#Preview {
    NavigationStack {
        KnownHostsView()
    }
}
