import SwiftUI

/// Interfaz del iPhone cuando hace de mando.
///
/// **Fase 0: esqueleto.** Cabecera con la marca y el estado de los periféricos.
/// El trackpad, los botones (Teclado, Dictado, Traer ventana, Atenuar) y los
/// ajustes llegan en la Fase 1.
///
/// Se deja que SwiftUI aplique Liquid Glass por defecto y sólo se tiñe con los
/// colores de BrunOS: nada de reconstruir los materiales a mano.
struct PhoneRootView: View {

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                brand
                statusCard
                Spacer()
                phaseNotice
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.brunosBackground)
        }
        .tint(.brunosAccent)
    }

    private var brand: some View {
        HStack(spacing: 0) {
            Text("brunOS")
                .foregroundStyle(Color.brunosText)
            Text("_")
                .foregroundStyle(Color.brunosAccent)
        }
        .font(.brunosMono(34, bold: true))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("BrunOS")
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Pantalla externa", value: "sin conectar")
            Divider().overlay(Color.brunosBorder)
            row("Ratón", value: "sin conectar")
            Divider().overlay(Color.brunosBorder)
            row("Teclado", value: "sin conectar")
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color.brunosPanel, in: .rect(cornerRadius: Tokens.Metric.paneCornerRadius))
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.brunosSans(15))
                .foregroundStyle(Color.brunosText)
            Spacer()
            Text(value)
                .font(.brunosMono(14))
                .foregroundStyle(Color.brunosTextSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var phaseNotice: some View {
        Text("Fase 0 · esqueleto")
            .font(.brunosMono(12))
            .foregroundStyle(Color.brunosTextSecondary)
    }
}

#Preview {
    PhoneRootView()
}
