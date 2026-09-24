import SwiftUI

/// El iPhone cuando hay monitor: **una superficie y nada más**.
///
/// **Por qué está apagado.** Con AssistiveTouch, el botón izquierdo del ratón
/// no llega a la app como botón: iOS lo convierte en un toque allí donde esté
/// el puntero **en la pantalla del teléfono**. Si en ese punto hay un botón de
/// la interfaz del iPhone, se pulsa ese botón y el escritorio del monitor ni se
/// entera. Con la cabecera y los botones puestos, hacer clic en el dock fallaba
/// según dónde hubiera quedado el puntero.
///
/// La única forma de que el clic llegue **siempre** al sitio correcto es que en
/// el iPhone no haya nada más que tocar. De ahí que los ajustes se hayan mudado
/// al monitor: aquí ya no cabrían.
///
/// Se queda casi negro también por batería y porque, mirando el monitor, una
/// pantalla encendida al lado sólo molesta.
struct RemoteModeView: View {

    private let services = AppServices.shared
    @State private var showsHint = true

    var body: some View {
        ZStack {
            // Sigue el modo del iPhone: Bruno no lo quería fijo en oscuro
            // (24-sep-2026).
            Color.brunosBackground.ignoresSafeArea()

            // Trackpad a pantalla completa. Es lo único que hay.
            TrackpadView(isFullScreen: true)
                .ignoresSafeArea()
                .accessibilityLabel("Superficie táctil")
                .accessibilityHint("Desliza para mover el puntero del monitor. "
                                   + "Toca para hacer clic. Dos dedos para desplazar.")

            if showsHint {
                hint
            }
        }
        .onAppear {
            // El aviso se va solo: la primera vez explica, después estorba.
            Task {
                try? await Task.sleep(for: .seconds(6))
                withAnimation(.easeOut(duration: 0.8)) { showsHint = false }
            }
        }
        // Tocar en cualquier sitio lo hace desaparecer antes.
        .onTapGesture { withAnimation { showsHint = false } }
    }

    private var hint: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                Text("brunOS").foregroundStyle(Color.brunosText)
                Text("_").foregroundStyle(Color.brunosAccent)
            }
            .font(.brunosMono(26, bold: true))

            Text("El iPhone es el mando")
                .font(.brunosSans(15, weight: .semibold))
                .foregroundStyle(Color.brunosText)

            VStack(alignment: .leading, spacing: 5) {
                line("Toda la pantalla es superficie táctil")
                line("Los ajustes están en el monitor, en el dock")
                line("Desconecta el monitor para volver aquí")
            }

            if let profile = services.externalDisplay.currentProfile {
                Text(profile.summary)
                    .font(.brunosMono(11))
                    .foregroundStyle(Color.brunosTextSecondary)
                    .padding(.top, 2)
            }
        }
        .padding(24)
        .background(Color.brunosPanelElevated.opacity(0.92), in: .rect(cornerRadius: 16))
        .padding(28)
        .transition(.opacity)
        // El aviso no se puede tocar: si no, sería otra cosa que robaría el
        // clic al trackpad, que es justo lo que se quería evitar.
        .allowsHitTesting(false)
    }

    private func line(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("·").foregroundStyle(Color.brunosAccent)
            Text(text)
                .font(.brunosSans(13))
                .foregroundStyle(Color.brunosTextSecondary)
        }
    }
}

#Preview {
    RemoteModeView()
}
