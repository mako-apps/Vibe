import UIKit

final class ChatMainProfileActionNode: UIControl {
  private let iconView = UIImageView()
  private let titleView = UILabel()
  private let pressedOverlay = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerCurve = .continuous

    iconView.contentMode = .scaleAspectFit
    addSubview(iconView)

    titleView.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    titleView.textAlignment = .center
    titleView.numberOfLines = 1
    addSubview(titleView)

    pressedOverlay.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
    pressedOverlay.alpha = 0
    pressedOverlay.isUserInteractionEnabled = false
    addSubview(pressedOverlay)
  }

  override var isHighlighted: Bool {
    didSet {
      let scale: CGFloat = isHighlighted ? 0.97 : 1.0
      let duration: TimeInterval = isHighlighted ? 0.08 : 0.18
      UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
        self.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.pressedOverlay.alpha = self.isHighlighted ? 1.0 : 0.0
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = 16
    iconView.frame = CGRect(x: (bounds.width - 24) * 0.5, y: 8, width: 24, height: 24)
    titleView.frame = CGRect(x: 6, y: iconView.frame.maxY + 6, width: bounds.width - 12, height: 17)
    pressedOverlay.frame = bounds
  }

  func configure(title: String, symbol: String) {
    titleView.text = title
    let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
    iconView.image = UIImage(systemName: symbol, withConfiguration: cfg)
  }

  func setTitle(_ title: String) {
    titleView.text = title
  }

  func applyTheme(foreground: UIColor, background: UIColor) {
    titleView.textColor = foreground
    iconView.tintColor = foreground
    self.backgroundColor = background
  }
}
