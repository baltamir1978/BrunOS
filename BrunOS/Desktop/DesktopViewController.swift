import UIKit

/// Raíz de la pantalla externa.
///
/// **Fase 0: esqueleto.** De momento sólo pinta el fondo y una tarjeta con lo que
/// el sistema dice de la pantalla, que es justo lo que hace falta para comprobar
/// que el accesorio de escena de iOS 27 funciona. El mosaico, la barra superior
/// y los paneles llegan en la Fase 1.
final class DesktopViewController: UIViewController {

    private let brandLabel = UILabel()
    private let detailLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = Tokens.Color.background

        // `brunOS_` con el guion bajo en ámbar.
        let brand = NSMutableAttributedString(
            string: "brunOS",
            attributes: [
                .font: Tokens.mono(48, bold: true),
                .foregroundColor: Tokens.Color.text,
            ]
        )
        brand.append(NSAttributedString(
            string: "_",
            attributes: [
                .font: Tokens.mono(48, bold: true),
                .foregroundColor: Tokens.Color.accent,
            ]
        ))
        brandLabel.attributedText = brand
        brandLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = Tokens.sans(18)
        detailLabel.textColor = Tokens.Color.textSecondary
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(brandLabel)
        view.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            brandLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            brandLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            detailLabel.topAnchor.constraint(equalTo: brandLabel.bottomAnchor, constant: 16),
            detailLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshDetail()
    }

    private func refreshDetail() {
        guard let screen = view.window?.windowScene?.screen else {
            detailLabel.text = "Sin pantalla"
            return
        }
        let native = screen.nativeBounds.size
        let profile = DisplayProfileStore().profile(forNativePixels: native)
        detailLabel.text = """
            \(Int(native.width))×\(Int(native.height)) px nativos
            \(profile.summary)
            """
    }
}
