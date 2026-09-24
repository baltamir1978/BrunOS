import UIKit

/// «Mira el iPhone»: un aviso en el monitor cada vez que algo sólo se puede
/// hacer en la pantalla del teléfono (elegir una carpeta, el paso por
/// Atajos).
///
/// Con el monitor delante, el iPhone está en negro y nadie lo mira: el
/// selector de carpetas salía allí y parecía que la app no hacía nada. Lo
/// pidió Bruno el 24-sep-2026. Se va solo; no se pulsa.
@MainActor
final class PhoneNotice: UIView {

    private let icon = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = Tokens.Color.panelElevated
        layer.cornerRadius = 12
        layer.borderWidth = 1.5
        setThemedBorder(Tokens.Color.accent)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 5)

        icon.image = UIImage(systemName: "iphone.gen3",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        icon.tintColor = Tokens.Color.accent
        icon.contentMode = .center
        addSubview(icon)

        label.font = Tokens.sans(14, weight: .medium)
        label.textColor = Tokens.Color.text
        label.numberOfLines = 2
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BrunOS no usa storyboards")
    }

    var text: String {
        get { label.text ?? "" }
        set { label.text = newValue }
    }

    /// El tamaño para un texto, con el ancho tope que se le dé.
    func fittingSize(maxWidth: CGFloat) -> CGSize {
        let textSize = label.sizeThatFits(CGSize(width: maxWidth - 64, height: 60))
        return CGSize(width: min(maxWidth, textSize.width + 64), height: max(48, textSize.height + 26))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = CGRect(x: 14, y: 0, width: 26, height: bounds.height)
        label.frame = CGRect(x: 48, y: 0, width: bounds.width - 62, height: bounds.height)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 12).cgPath
    }
}
