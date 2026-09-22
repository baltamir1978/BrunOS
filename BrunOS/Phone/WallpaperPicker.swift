import SwiftUI

/// Elegir el fondo del escritorio.
///
/// Los degradados se pintan en la propia vista previa con los mismos colores
/// que usa el escritorio, así que lo que se ve aquí es lo que va a salir en el
/// monitor, no una aproximación.
struct WallpaperPicker: View {

    private let services = AppServices.shared

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(services.wallpaper.available.enumerated()), id: \.offset) { _, wallpaper in
                    Button {
                        services.wallpaper.current = wallpaper
                    } label: {
                        preview(for: wallpaper)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)

            if services.wallpaper.imageNames.isEmpty {
                footer
            }
        }
        .background(Color.brunosBackground)
        .navigationTitle("Fondo")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func preview(for wallpaper: Wallpaper) -> some View {
        let isSelected = services.wallpaper.current == wallpaper

        VStack(spacing: 6) {
            ZStack {
                switch wallpaper {
                case .solid:
                    Color.brunosBackground
                case .gradient(let gradient):
                    GradientPreview(gradient: gradient)
                case .image(let name):
                    ImagePreview(name: name)
                case .file, .custom:
                    Color.brunosPanel
                        .overlay { Image(systemName: "photo").foregroundStyle(Color.brunosTextSecondary) }
                }
            }
            .frame(height: 62)
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.brunosAccent : Color.brunosBorder,
                        lineWidth: isSelected ? 2 : 1
                    )
            }

            Text(wallpaper.label)
                .font(.brunosSans(11))
                .foregroundStyle(isSelected ? Color.brunosAccent : Color.brunosTextSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(wallpaper.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var footer: some View {
        Text("Para añadir los fondos de macOS, ejecuta `Tools/fetch-wallpapers.sh` en el Mac "
             + "y vuelve a compilar. No vienen incluidos porque son de Apple y este "
             + "repositorio es público.\n\nMás adelante se podrá elegir cualquier imagen "
             + "desde el gestor de ficheros.")
            .font(.brunosSans(12))
            .foregroundStyle(Color.brunosTextSecondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
    }
}

/// Vista previa de un degradado, con el mismo resplandor que el escritorio.
private struct GradientPreview: View {
    let gradient: Wallpaper.Gradient

    var body: some View {
        let glow = gradient.glow(for: DesktopTheme.style)
        ZStack {
            LinearGradient(
                colors: gradient.colors(for: DesktopTheme.style).map(Color.init),
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color(glow.color), Color(glow.color).opacity(0)],
                center: UnitPoint(x: glow.center.x, y: glow.center.y),
                startRadius: 0,
                endRadius: 70
            )
            .opacity(Double(gradient.glowOpacity))
        }
    }
}

private struct ImagePreview: View {
    let name: String

    var body: some View {
        if let url = Bundle.main.url(
            forResource: (name as NSString).deletingPathExtension,
            withExtension: (name as NSString).pathExtension,
            subdirectory: "Wallpapers"
        ), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Color.brunosPanel
        }
    }
}

#Preview {
    NavigationStack {
        WallpaperPicker()
    }
}
