import SwiftUI

/// Lista de máquinas a las que conectarse.
struct HostsView: View {

    private let services = AppServices.shared
    @State private var editing: SSHHost?

    var body: some View {
        List {
            tailscaleSection

            Section("Máquinas") {
                if services.hosts.hosts.isEmpty {
                    Text("Todavía no hay ninguna. Añade una con el + de arriba.")
                        .font(.brunosSans(14))
                        .foregroundStyle(Color.brunosTextSecondary)
                }

                ForEach(services.hosts.hosts) { host in
                    Button {
                        editing = host
                    } label: {
                        row(for: host)
                    }
                    .tint(Color.brunosText)
                }
                .onDelete { offsets in
                    for index in offsets {
                        services.hosts.remove(services.hosts.hosts[index])
                    }
                }
            }
        }
        .navigationTitle("Hosts SSH")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Añadir", systemImage: "plus") {
                    editing = SSHHost()
                }
            }
        }
        .sheet(item: $editing) { host in
            HostEditorView(host: host)
        }
        .onAppear { services.tailscale.refresh() }
    }

    private func row(for host: SSHHost) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(host.displayName)
                .font(.brunosSans(16, weight: .medium))
            Text("\(host.username)@\(host.host):\(host.port) · \(host.authentication.label)")
                .font(.brunosMono(12))
                .foregroundStyle(Color.brunosTextSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Sólo se avisa si de verdad hace falta: con algún host configurado para
    /// entrar por Tailscale. Quien use SSH con contraseña contra una máquina de
    /// su red no tiene por qué ver nada de esto.
    private var usesTailscale: Bool {
        services.hosts.hosts.contains { $0.authentication == .tailscale }
    }

    /// Aviso, nunca impedimento.
    ///
    /// No hay forma de preguntarle a Tailscale por su estado, así que esto se
    /// deduce de las interfaces de red y **puede equivocarse**. Por eso se
    /// rotula como sospecha y no impide conectarse a nada.
    @ViewBuilder
    private var tailscaleSection: some View {
        if usesTailscale, !services.tailscale.isLikelyUp {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tailscale no parece estar activo")
                        .font(.brunosSans(15, weight: .semibold))
                        .foregroundStyle(Color.brunosAccent)
                    Text("No se ve ninguna interfaz con dirección del tailnet. Si vas a "
                         + "conectarte por Tailscale, ábrelo y comprueba que esté conectado.")
                        .font(.brunosSans(13))
                        .foregroundStyle(Color.brunosTextSecondary)
                    Text("Es sólo un aviso: se deduce de la red y puede equivocarse. No "
                         + "impide conectarse.")
                        .font(.brunosSans(12))
                        .foregroundStyle(Color.brunosTextSecondary)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Alta y edición de una máquina.
struct HostEditorView: View {

    @Environment(\.dismiss) private var dismiss
    private let services = AppServices.shared

    @State private var host: SSHHost
    @State private var password = ""
    @State private var hadPassword = false

    init(host: SSHHost) {
        _host = State(initialValue: host)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identificación") {
                    LabeledContent("Nombre") {
                        TextField("homelab", text: $host.name)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Host") {
                        TextField("homelab", text: $host.host)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Usuario") {
                        TextField("bruno", text: $host.username)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Puerto") {
                        TextField("22", value: $host.port, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                }
                .font(.brunosMono(14))

                Section {
                    Picker("Método", selection: $host.authentication) {
                        ForEach(SSHHost.Authentication.allCases, id: \.self) { method in
                            Text(method.label).tag(method)
                        }
                    }

                    if host.authentication == .password {
                        SecureField(
                            hadPassword ? "Guardada · escribe para cambiarla" : "Contraseña",
                            text: $password
                        )
                        .font(.brunosMono(14))
                    }
                } header: {
                    Text("Autenticación")
                } footer: {
                    Text(host.authentication == .tailscale
                         ? "Tailscale autentica por la identidad del tailnet, así que no hace "
                           + "falta contraseña. Requiere que Tailscale SSH esté activado en esa "
                           + "máquina."
                         : host.authentication == .key
                         ? "Usa la clave ed25519 del iPhone. Su parte pública se copia desde los "
                           + "ajustes del terminal en el monitor, y va en el authorized_keys de "
                           + "la máquina."
                         : "La contraseña se guarda en el Keychain de este iPhone. **No se "
                           + "sincroniza con iCloud y no se puede leer con el teléfono "
                           + "bloqueado.**")
                }

                Section {
                    TextField("tmux new -As main", text: $host.initialCommand)
                        .font(.brunosMono(14))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Comando inicial")
                } footer: {
                    Text("Opcional. Se ejecuta nada más entrar.")
                }
            }
            .navigationTitle(host.name.isEmpty ? "Nueva máquina" : host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") { save() }
                        .disabled(host.host.isEmpty || host.username.isEmpty)
                }
            }
            .onAppear {
                hadPassword = SSHKeychain.hasPassword(for: host)
            }
        }
        .tint(.brunosAccent)
    }

    private func save() {
        services.hosts.upsert(host)
        // Sólo se toca el Keychain si se escribió algo: dejar el campo vacío
        // significa "no la cambies", no "bórrala".
        if host.authentication == .password, !password.isEmpty {
            SSHKeychain.setPassword(password, for: host)
        }
        dismiss()
    }
}

#Preview {
    NavigationStack {
        HostsView()
    }
}
