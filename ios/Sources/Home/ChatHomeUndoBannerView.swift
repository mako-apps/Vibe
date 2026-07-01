import UIKit

final class ChatHomeUndoBannerView: UIControl {
  static let preferredHeight: CGFloat = 58.0

  private let blurView = UIVisualEffectView(effect: nil)
  private let iconContainer = UIView()
  private let iconImageView = UIImageView()
  private let titleLabel = UILabel()
  private let bodyLabel = UILabel()
  private let textStack = UIStackView()
  private let actionPillView = UIView()
  private let actionLabel = UILabel()
  private let timerBackgroundLayer = CAShapeLayer()
  private let timerProgressLayer = CAShapeLayer()
  private var isTimerAnimating = false
  private var destructive = true

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    title: String,
    body: String,
    actionTitle: String,
    timerText: String,
    destructive: Bool
  ) {
    self.destructive = destructive
    titleLabel.text = title
    bodyLabel.text = body
    actionLabel.text = actionTitle
    iconImageView.image = UIImage(
      systemName: destructive ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill"
    )

    if timerText.isEmpty {
      timerProgressLayer.removeAllAnimations()
      isTimerAnimating = false
    } else {
      let secondsString = timerText.trimmingCharacters(in: CharacterSet(charactersIn: "sS "))
      let seconds = Double(secondsString) ?? 5.0
      if !isTimerAnimating && seconds > 0 {
        isTimerAnimating = true
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = seconds / 5.0
        anim.toValue = 0
        anim.duration = seconds
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards
        timerProgressLayer.add(anim, forKey: "countdown")
        timerProgressLayer.strokeEnd = 0
      }
    }
  }

  func applyTheme(textColor: UIColor, surfaceColor: UIColor, isDark: Bool) {
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = true
      blurView.effect = glass
      blurView.contentView.backgroundColor = .clear
    } else {
      blurView.effect = UIBlurEffect(style: .systemThinMaterial)
      blurView.contentView.backgroundColor = surfaceColor.withAlphaComponent(isDark ? 0.16 : 0.10)
    }

    let accentColor = textColor

    blurView.alpha = isDark ? 0.98 : 0.95
    blurView.layer.borderColor = textColor.withAlphaComponent(isDark ? 0.10 : 0.06).cgColor

    iconContainer.backgroundColor = accentColor.withAlphaComponent(isDark ? 0.12 : 0.08)
    iconImageView.tintColor = accentColor
    titleLabel.textColor = textColor.withAlphaComponent(0.96)
    bodyLabel.textColor = textColor.withAlphaComponent(0.78)

    actionPillView.backgroundColor = accentColor.withAlphaComponent(isDark ? 0.12 : 0.08)
    actionPillView.layer.borderColor = accentColor.withAlphaComponent(isDark ? 0.14 : 0.10).cgColor
    actionLabel.textColor = accentColor
    
    timerBackgroundLayer.strokeColor = textColor.withAlphaComponent(isDark ? 0.15 : 0.08).cgColor
    timerProgressLayer.strokeColor = textColor.withAlphaComponent(0.70).cgColor
  }

  private func setup() {
    backgroundColor = .clear

    addSubview(blurView)
    blurView.layer.cornerCurve = .continuous
    blurView.layer.cornerRadius = 99.0
    blurView.layer.borderWidth = 1.0
    blurView.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
    blurView.clipsToBounds = true

    blurView.contentView.addSubview(iconContainer)
    blurView.contentView.addSubview(textStack)
    blurView.contentView.addSubview(actionPillView)
    blurView.contentView.layer.addSublayer(timerBackgroundLayer)
    blurView.contentView.layer.addSublayer(timerProgressLayer)

    timerBackgroundLayer.lineWidth = 2.5
    timerBackgroundLayer.fillColor = UIColor.clear.cgColor
    timerProgressLayer.lineWidth = 2.5
    timerProgressLayer.fillColor = UIColor.clear.cgColor
    timerProgressLayer.lineCap = .round

    iconContainer.layer.cornerCurve = .continuous
    iconContainer.layer.cornerRadius = 15.0
    iconContainer.addSubview(iconImageView)

    iconImageView.contentMode = .scaleAspectFit
    iconImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 16,
      weight: .semibold
    )

    titleLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail

    bodyLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
    bodyLabel.numberOfLines = 1
    bodyLabel.lineBreakMode = .byTruncatingTail

    textStack.axis = .vertical
    textStack.alignment = .fill
    textStack.distribution = .fill
    textStack.spacing = 1.0
    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(bodyLabel)

    actionPillView.layer.cornerCurve = .continuous
    actionPillView.layer.cornerRadius = 15.0
    actionPillView.layer.borderWidth = 1.0
    actionPillView.addSubview(actionLabel)

    actionLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
    actionLabel.textAlignment = .center
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    blurView.frame = bounds

    let iconSize: CGFloat = 30.0
    iconContainer.frame = CGRect(
      x: 10.0,
      y: (bounds.height - iconSize) * 0.5,
      width: iconSize,
      height: iconSize
    )
    iconImageView.frame = iconContainer.bounds.insetBy(dx: 7.0, dy: 7.0)

    let actionWidth: CGFloat = 66.0
    let actionX = max(0, bounds.width - actionWidth - 14.0)
    actionPillView.frame = CGRect(x: actionX, y: 8.0, width: actionWidth, height: 30.0)
    actionLabel.frame = actionPillView.bounds.insetBy(dx: 8.0, dy: 6.0)
    
    let timerRadius: CGFloat = 6.0
    let timerCenter = CGPoint(x: actionX + actionWidth / 2.0, y: actionPillView.frame.maxY + 8.0)
    let timerPath = UIBezierPath(arcCenter: timerCenter, radius: timerRadius, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true)
    timerBackgroundLayer.path = timerPath.cgPath
    timerProgressLayer.path = timerPath.cgPath

    let textX = iconContainer.frame.maxX + 10.0
    let textWidth = max(0.0, actionX - textX - 10.0)
    textStack.frame = CGRect(
      x: textX,
      y: 8.0,
      width: textWidth,
      height: max(0.0, bounds.height - 16.0)
    )
  }
}
