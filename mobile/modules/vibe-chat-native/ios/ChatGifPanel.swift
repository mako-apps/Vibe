import UIKit

#if canImport(GiphyUISDK)
    import GiphyUISDK
#endif

private let chatGifDefaultApiKey = "dc6zaTOxFJmzC"

final class ChatGifPanelConfig {
    static let shared = ChatGifPanelConfig()

    private init() {}

    var apiKey: String = chatGifDefaultApiKey
}

struct ChatGifSelection {
    let id: String
    let url: String
    let previewUrl: String
    let width: Int
    let height: Int
}

protocol ChatGifPanelViewDelegate: AnyObject {
    func chatGifPanel(_ panel: ChatGifPanelView, didSelectGif gif: ChatGifSelection)
    func chatGifPanelDidRequestClose(_ panel: ChatGifPanelView)
}

final class ChatGifPanelView: UIView {
    weak var delegate: ChatGifPanelViewDelegate?
    weak var hostViewController: UIViewController? {
        didSet {
            guard hostViewController !== oldValue else { return }
            removeEmbeddedPicker()
            installEmbeddedPickerIfNeeded()
        }
    }

    private let glassBackground = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let headerView = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let contentView = UIView()
    private let fallbackLabel = UILabel()

    #if canImport(GiphyUISDK)
        private var pickerViewController: GiphyViewController?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        removeEmbeddedPicker()
    }

    func prepareIfNeeded() {
        installEmbeddedPickerIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let headerH: CGFloat = 42
        headerView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerH)
        titleLabel.frame = CGRect(x: 12, y: 0, width: max(1, bounds.width - 80), height: headerH)
        closeButton.frame = CGRect(x: bounds.width - 40, y: 5, width: 32, height: 32)
        contentView.frame = CGRect(
            x: 0, y: headerH, width: bounds.width, height: max(0, bounds.height - headerH))
        fallbackLabel.frame = contentView.bounds.insetBy(dx: 20, dy: 20)

        #if canImport(GiphyUISDK)
            pickerViewController?.view.frame = contentView.bounds
        #endif
    }

    @objc private func closeTapped() {
        delegate?.chatGifPanelDidRequestClose(self)
    }

    private func setupUI() {
        clipsToBounds = true
        backgroundColor = .clear

        glassBackground.frame = bounds
        glassBackground.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glassBackground)

        headerView.backgroundColor = .clear
        addSubview(headerView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = UIColor(white: 0.95, alpha: 0.9)
        titleLabel.text = "GIFs"
        headerView.addSubview(titleLabel)

        let closeCfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: closeCfg), for: .normal)
        closeButton.tintColor = UIColor(white: 0.95, alpha: 0.85)
        closeButton.backgroundColor = UIColor(white: 0.2, alpha: 0.35)
        closeButton.layer.cornerRadius = 16
        closeButton.layer.cornerCurve = .continuous
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        headerView.addSubview(closeButton)

        contentView.backgroundColor = .clear
        addSubview(contentView)

        fallbackLabel.text = "Install the Giphy native SDK to enable GIF search."
        fallbackLabel.font = .systemFont(ofSize: 14)
        fallbackLabel.textColor = UIColor(white: 0.84, alpha: 0.78)
        fallbackLabel.textAlignment = .center
        fallbackLabel.numberOfLines = 0
        fallbackLabel.isHidden = true
        contentView.addSubview(fallbackLabel)

        installEmbeddedPickerIfNeeded()
    }

    private func configureGiphySDKIfNeeded() {
        #if canImport(GiphyUISDK)
            let key = ChatGifPanelConfig.shared.apiKey.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            Giphy.configure(apiKey: key)
        #endif
    }

    private func installEmbeddedPickerIfNeeded() {
        #if canImport(GiphyUISDK)
            guard pickerViewController == nil else { return }
            guard let host = hostViewController else {
                fallbackLabel.isHidden = false
                return
            }

            configureGiphySDKIfNeeded()

            let picker = GiphyViewController()
            picker.delegate = self
            picker.mediaTypeConfig = [.gifs]

            host.addChild(picker)
            contentView.addSubview(picker.view)
            picker.view.frame = contentView.bounds
            picker.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            picker.didMove(toParent: host)

            pickerViewController = picker
            fallbackLabel.isHidden = true
        #else
            fallbackLabel.isHidden = false
        #endif
    }

    private func removeEmbeddedPicker() {
        #if canImport(GiphyUISDK)
            guard let picker = pickerViewController else { return }
            picker.willMove(toParent: nil)
            picker.view.removeFromSuperview()
            picker.removeFromParent()
            pickerViewController = nil
        #endif
    }

    private func unwrapOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first?.value
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        let unwrapped = unwrapOptional(value)
        guard let unwrapped else { return nil }

        if let string = unwrapped as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let url = unwrapped as? URL {
            let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        let described = String(describing: unwrapped).trimmingCharacters(
            in: .whitespacesAndNewlines)
        if described.isEmpty || described == "nil" {
            return nil
        }
        return described
    }

    private func intValue(_ value: Any?) -> Int? {
        guard let value else { return nil }
        let unwrapped = unwrapOptional(value)
        guard let unwrapped else { return nil }

        if let intValue = unwrapped as? Int {
            return intValue
        }
        if let numberValue = unwrapped as? NSNumber {
            return numberValue.intValue
        }
        if let stringValue = unwrapped as? String,
            let parsed = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return parsed
        }
        return nil
    }

    private func value(for selectors: [String], on object: NSObject) -> Any? {
        var current: AnyObject? = object
        for selectorName in selectors {
            guard let target = current else { return nil }
            guard let nsTarget = target as? NSObject else { return nil }
            let selector = NSSelectorFromString(selectorName)
            guard nsTarget.responds(to: selector), let result = nsTarget.perform(selector) else {
                return nil
            }
            current = result.takeUnretainedValue()
        }
        return current
    }
}

#if canImport(GiphyUISDK)
    extension ChatGifPanelView: GiphyDelegate {
        func didDismiss(controller: GiphyViewController?) {
            delegate?.chatGifPanelDidRequestClose(self)
        }

        func didSelectMedia(
            giphyViewController: GiphyViewController,
            media: GPHMedia
        ) {
            emitSelection(media: media)
        }

        func didSelectMedia(
            giphyViewController: GiphyViewController,
            media: GPHMedia,
            contentType: GPHContentType
        ) {
            emitSelection(media: media)
        }

        private func emitSelection(media: GPHMedia) {
            let mediaObject = media as NSObject

            let id =
                stringValue(value(for: ["id"], on: mediaObject))
                ?? UUID().uuidString.lowercased()

            let urlCandidates: [String] = [
                stringValue(value(for: ["images", "original", "gifUrl"], on: mediaObject)),
                stringValue(value(for: ["images", "fixedWidth", "gifUrl"], on: mediaObject)),
                stringValue(value(for: ["images", "fixedHeight", "gifUrl"], on: mediaObject)),
                stringValue(value(for: ["url"], on: mediaObject)),
            ].compactMap { $0 }

            guard let url = urlCandidates.first else { return }

            let previewCandidates: [String] = [
                stringValue(value(for: ["images", "previewGif", "gifUrl"], on: mediaObject)),
                stringValue(
                    value(for: ["images", "fixedWidthSmallStill", "gifUrl"], on: mediaObject)),
                stringValue(value(for: ["images", "fixedWidthStill", "gifUrl"], on: mediaObject)),
                url,
            ].compactMap { $0 }

            let width = intValue(value(for: ["images", "original", "width"], on: mediaObject)) ?? 0
            let height =
                intValue(value(for: ["images", "original", "height"], on: mediaObject)) ?? 0

            delegate?.chatGifPanel(
                self,
                didSelectGif: ChatGifSelection(
                    id: id,
                    url: url,
                    previewUrl: previewCandidates.first ?? url,
                    width: width,
                    height: height
                )
            )
        }
    }
#endif
