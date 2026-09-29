import PhotosUI
import SwiftUI

/// Elegir el fondo del escritorio desde el iPhone, lo mismo que Ajustes ›
/// Fondo en el monitor, más una foto de la fototeca.
///
/// Las miniaturas salen de `WallpaperStore.thumbnail`, el mismo código que
/// pinta el escritorio, así que lo que se ve aquí es lo que va a salir en el
/// monitor, no una aproximación.
struct WallpaperPicker: View {

    private let services = AppServices.shared

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    /// La foto elegida en la fototeca, mientras se copia.
    @State private var photo: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importError: String?

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

            // `PhotosPicker` corre fuera de la app: no pide permiso para leer
            // la fototeca, sólo entrega la foto que se elige.
            PhotosPicker(selection: $photo, matching: .images) {
                Label(isImporting ? "Preparando la foto…" : "Elegir una foto…", systemImage: "photo.on.rectangle")
                    .font(.brunosSans(15))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .disabled(isImporting)
            .padding(.horizontal, 16)

            if let importError {
                Text(importError)
                    .font(.brunosSans(12))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }

            footer
        }
        .background(Color.brunosBackground)
        .navigationTitle("Fondo")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            importPhoto(item)
        }
    }

    /// Copia la foto como imagen propia, igual que «Usar como fondo de
    /// escritorio» en Ficheros: `setCustomImage` la reduce y la guarda.
    private func importPhoto(_ item: PhotosPickerItem) {
        isImporting = true
        importError = nil
        Task {
            defer {
                isImporting = false
                photo = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    importError = "No se pudo leer la foto."
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try data.write(to: url, options: .atomic)
                defer { try? FileManager.default.removeItem(at: url) }
                try services.wallpaper.setCustomImage(from: url)
            } catch {
                importError = "No se pudo usar la foto: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func preview(for wallpaper: Wallpaper) -> some View {
        let isSelected = services.wallpaper.current == wallpaper

        VStack(spacing: 6) {
            Image(uiImage: services.wallpaper.thumbnail(for: wallpaper, size: CGSize(width: 160, height: 100)))
                .resizable()
                .scaledToFill()
                .frame(height: 62)
                .frame(maxWidth: .infinity)
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
        Text("También se puede poner cualquier imagen desde Ficheros, con el botón derecho › "
             + "«Usar como fondo de escritorio». Los fondos de macOS salen si se ejecuta "
             + "`Tools/fetch-wallpapers.sh` en el Mac antes de compilar: no vienen incluidos "
             + "porque son de Apple y este repositorio es público.")
            .font(.brunosSans(12))
            .foregroundStyle(Color.brunosTextSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
    }
}

#Preview {
    NavigationStack {
        WallpaperPicker()
    }
}
