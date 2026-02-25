import UIKit

final class ChatMainProfileTabNode: UIControl {
  private let titleLabel = UILabel()
  private let pressedOverlay = UIView()

  private var normalTextColor: UIColor = .secondaryLabel
  private var activeTextColor: UIColor = .label
  private var activeBackgroundColor: UIColor = UIColor(white: 1.0, alpha: 0.12)

  var isActive: Bool = false {
    didSet { applyState() }
  }

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
    layer.cornerRadius = 18.0

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
    titleLabel.textAlignment = .center
    addSubview(titleLabel)

    pressedOverlay.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
    pressedOverlay.alpha = 0.0
    pressedOverlay.isUserInteractionEnabled = false
    addSubview(pressedOverlay)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    titleLabel.frame = bounds.insetBy(dx: 14.0, dy: 6.0)
    pressedOverlay.frame = bounds
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: isHighlighted ? 0.08 : 0.18, delay: 0.0, options: [.curveEaseOut, .allowUserInteraction]) {
        self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
        self.pressedOverlay.alpha = self.isHighlighted ? 1.0 : 0.0
      }
    }
  }

  func setTitle(_ title: String) {
    titleLabel.text = title
  }

  func applyTheme(
    activeTextColor: UIColor,
    normalTextColor: UIColor,
    activeBackgroundColor: UIColor
  ) {
    self.activeTextColor = activeTextColor
    self.normalTextColor = normalTextColor
    self.activeBackgroundColor = activeBackgroundColor
    applyState()
  }

  private func applyState() {
    backgroundColor = isActive ? activeBackgroundColor : .clear
    titleLabel.textColor = isActive ? activeTextColor : normalTextColor
  }
}

final class ChatMainProfileListRowNode: UIControl {
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let separatorView = UIView()
  private let pressedOverlay = UIView()

  private var defaultTitleColor: UIColor = .label
  private var subtitleColor: UIColor = .secondaryLabel
  private var separatorColor: UIColor = UIColor(white: 1.0, alpha: 0.08)
  private var highlightedColor: UIColor = UIColor(white: 1.0, alpha: 0.04)
  private var titleColorOverride: UIColor?

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

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
    titleLabel.numberOfLines = 1
    addSubview(titleLabel)

    subtitleLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    subtitleLabel.numberOfLines = 2
    addSubview(subtitleLabel)

    separatorView.backgroundColor = separatorColor
    addSubview(separatorView)

    pressedOverlay.backgroundColor = highlightedColor
    pressedOverlay.alpha = 0.0
    pressedOverlay.isUserInteractionEnabled = false
    addSubview(pressedOverlay)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let insetX: CGFloat = 18.0
    titleLabel.frame = CGRect(x: insetX, y: 11.0, width: bounds.width - (insetX * 2.0), height: 22.0)
    let subtitleHeight = max(0.0, bounds.height - titleLabel.frame.maxY - 11.0)
    subtitleLabel.frame = CGRect(
      x: insetX,
      y: titleLabel.frame.maxY + 1.0,
      width: bounds.width - (insetX * 2.0),
      height: subtitleHeight
    )
    separatorView.frame = CGRect(
      x: insetX,
      y: bounds.height - (1.0 / UIScreen.main.scale),
      width: max(0.0, bounds.width - (insetX * 2.0)),
      height: 1.0 / UIScreen.main.scale
    )
    pressedOverlay.frame = bounds
  }

  override var isHighlighted: Bool {
    didSet {
      guard isEnabled else { return }
      UIView.animate(withDuration: isHighlighted ? 0.08 : 0.16, delay: 0.0, options: [.curveEaseOut, .allowUserInteraction]) {
        self.pressedOverlay.alpha = self.isHighlighted ? 1.0 : 0.0
      }
    }
  }

  func configure(
    title: String,
    subtitle: String,
    titleColor: UIColor? = nil,
    showsSeparator: Bool
  ) {
    titleLabel.text = title
    subtitleLabel.text = subtitle
    titleColorOverride = titleColor
    separatorView.isHidden = !showsSeparator
    titleLabel.textColor = titleColor ?? defaultTitleColor
    subtitleLabel.textColor = subtitleColor
  }

  func applyTheme(
    titleColor: UIColor,
    subtitleColor: UIColor,
    separatorColor: UIColor,
    highlightedColor: UIColor
  ) {
    defaultTitleColor = titleColor
    self.subtitleColor = subtitleColor
    self.separatorColor = separatorColor
    self.highlightedColor = highlightedColor
    titleLabel.textColor = titleColorOverride ?? titleColor
    subtitleLabel.textColor = subtitleColor
    separatorView.backgroundColor = separatorColor
    pressedOverlay.backgroundColor = highlightedColor
  }
}

final class ChatMainProfileMediaCellNode: UIControl {
  private static let imageCache = NSCache<NSString, UIImage>()

  private let imageView = UIImageView()
  private let placeholderIcon = UIImageView()
  private let videoBadge = UIView()
  private let videoBadgeLabel = UILabel()

  private var imageLoadTask: URLSessionDataTask?
  private var imageURLString: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  deinit {
    imageLoadTask?.cancel()
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerCurve = .continuous
    layer.cornerRadius = 3.0

    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.isHidden = true
    addSubview(imageView)

    placeholderIcon.contentMode = .scaleAspectFit
    placeholderIcon.image = UIImage(systemName: "photo")
    addSubview(placeholderIcon)

    videoBadge.backgroundColor = UIColor(white: 0.0, alpha: 0.58)
    videoBadge.layer.cornerRadius = 7.0
    videoBadge.layer.cornerCurve = .continuous
    videoBadge.isHidden = true
    addSubview(videoBadge)

    videoBadgeLabel.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
    videoBadgeLabel.text = "VIDEO"
    videoBadgeLabel.textColor = .white
    videoBadgeLabel.textAlignment = .center
    videoBadge.addSubview(videoBadgeLabel)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = bounds
    placeholderIcon.frame = bounds.insetBy(dx: bounds.width * 0.3, dy: bounds.height * 0.3)

    let badgeHeight: CGFloat = 16.0
    let badgeWidth: CGFloat = 48.0
    videoBadge.frame = CGRect(
      x: max(0.0, bounds.width - badgeWidth - 6.0),
      y: max(0.0, bounds.height - badgeHeight - 6.0),
      width: badgeWidth,
      height: badgeHeight
    )
    videoBadgeLabel.frame = videoBadge.bounds.insetBy(dx: 4.0, dy: 1.0)
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: isHighlighted ? 0.08 : 0.16, delay: 0.0, options: [.curveEaseOut, .allowUserInteraction]) {
        self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
        self.alpha = self.isHighlighted ? 0.86 : 1.0
      }
    }
  }

  func configure(urlString: String?, isVideo: Bool) {
    videoBadge.isHidden = !isVideo
    imageLoadTask?.cancel()
    imageLoadTask = nil
    imageView.image = nil
    imageView.isHidden = true
    placeholderIcon.isHidden = false
    imageURLString = nil

    guard let urlString, !urlString.isEmpty else { return }
    imageURLString = urlString

    if let cached = Self.imageCache.object(forKey: urlString as NSString) {
      imageView.image = cached
      imageView.isHidden = false
      placeholderIcon.isHidden = true
      return
    }

    guard let url = URL(string: urlString) else { return }
    if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
      Self.imageCache.setObject(image, forKey: urlString as NSString)
      imageView.image = image
      imageView.isHidden = false
      placeholderIcon.isHidden = true
      return
    }

    let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      Self.imageCache.setObject(image, forKey: urlString as NSString)
      DispatchQueue.main.async {
        guard self.imageURLString == urlString else { return }
        self.imageView.image = image
        self.imageView.isHidden = false
        self.placeholderIcon.isHidden = true
      }
    }
    imageLoadTask = task
    task.resume()
  }

  func applyTheme(placeholderTintColor: UIColor, placeholderBackgroundColor: UIColor) {
    backgroundColor = placeholderBackgroundColor
    placeholderIcon.tintColor = placeholderTintColor
  }
}
