import SwiftUI

/// La hoja del iPhone donde iOS ofrece las contraseñas guardadas.
///
/// Son campos nativos con `textContentType` de usuario y contraseña: con eso,
/// iOS pone encima del teclado la llave de Contraseñas y, tras Face ID, deja
/// elegir cualquiera de las guardadas, las mismas que usa Safari. Al elegir una,
/// iOS rellena los dos campos de golpe, y eso se reconoce y se manda a la
/// página sin tener que pulsar nada más.
struct PasswordAutoFillView: View {

    let request: PasswordBridge.Request
    private let bridge = AppServices.shared.passwords

    @State private var username = ""
    @State private var password = ""
    @FocusState private var focused: Field?

    private enum Field { case username, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Usuario o correo", text: $username)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                    SecureField("Contraseña", text: $password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .submitLabel(.done)
                        .onSubmit(fill)
                } header: {
                    Text(request.host)
                } footer: {
                    Text("Toca la llave de encima del teclado para elegir una contraseña guardada. "
                         + "BrunOS la pasa a la página del monitor y no la guarda.")
                }
            }
            .navigationTitle("Contraseña")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { bridge.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rellenar", action: fill)
                        .disabled(password.isEmpty && username.isEmpty)
                }
            }
            .onAppear { focused = .username }
            // Con la hoja abierta, el teclado físico escribe aquí y no llega al
            // monitor: Esc tiene que poder cerrarla desde aquí.
            .onKeyPress(.escape) {
                bridge.cancel()
                return .handled
            }
            // El autorrelleno escribe la contraseña entera de una vez; a mano
            // se escribe letra a letra. Un salto de más de un carácter es iOS
            // eligiendo una contraseña guardada: se manda sin esperar.
            .onChange(of: password) { old, new in
                if new.count - old.count > 1 { fill() }
            }
        }
        .tint(.brunosAccent)
    }

    private func fill() {
        guard !password.isEmpty || !username.isEmpty else { return }
        bridge.complete(username: username, password: password)
        username = ""
        password = ""
    }
}
