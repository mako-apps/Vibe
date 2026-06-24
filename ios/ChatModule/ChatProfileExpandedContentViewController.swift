import UIKit

class ChatProfileExpandedContentViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
  
  let tab: ChatProfileTab
  let rows: [Any]
  let themeIsDark: Bool
  var onContentPressed: (([String: Any]) -> Void)?
  
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let headerBlur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let titleLabel = UILabel()
  private let closeButton = UIButton(type: .system)
  
  private let transition = GlassMorphTransition()
  
  init(tab: ChatProfileTab, rows: [Any], themeIsDark: Bool, sourceView: UIView, hostView: UIView) {
    self.tab = tab
    self.rows = rows
    self.themeIsDark = themeIsDark
    super.init(nibName: nil, bundle: nil)
    self.modalPresentationStyle = .overFullScreen
    
    transition.hostView = hostView
    transition.sourceView = sourceView
    transition.targetView = self.view
    transition.config.blurRadius = 16.0
  }
  
  required init?(coder: NSCoder) {
    fatalError()
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = themeIsDark ? UIColor.black.withAlphaComponent(0.6) : UIColor.white.withAlphaComponent(0.6)
    
    tableView.dataSource = self
    tableView.delegate = self
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    tableView.contentInset = UIEdgeInsets(top: 60, left: 0, bottom: 20, right: 0)
    
    tableView.register(ChatProfileVoiceContentCell.self, forCellReuseIdentifier: ChatProfileVoiceContentCell.reuseIdentifier)
    tableView.register(ChatProfileMediaGridRowCell.self, forCellReuseIdentifier: ChatProfileMediaGridRowCell.reuseIdentifier)
    tableView.register(ChatProfileMediaContentCell.self, forCellReuseIdentifier: ChatProfileMediaContentCell.reuseIdentifier)
    tableView.register(ChatProfileListRowCell.self, forCellReuseIdentifier: ChatProfileListRowCell.reuseIdentifier)
    
    view.addSubview(tableView)
    
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: .regular)
      effect.isInteractive = true
      headerBlur.effect = effect
    } else {
      headerBlur.effect = UIBlurEffect(style: themeIsDark ? .systemMaterialDark : .systemMaterialLight)
    }
    view.addSubview(headerBlur)
    
    titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
    titleLabel.textColor = themeIsDark ? .white : .black
    titleLabel.text = sharedTitle(for: tab)
    headerBlur.contentView.addSubview(titleLabel)
    
    closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    closeButton.tintColor = themeIsDark ? .lightGray : .darkGray
    closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    headerBlur.contentView.addSubview(closeButton)
    
    transition.suppressTargetForInitialState()
  }
  
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if isBeingPresented {
      transition.animatePresent(completion: nil)
    }
  }
  
  @objc private func handleClose() {
    transition.animateDismiss { [weak self] in
      self?.dismiss(animated: false)
    }
  }
  
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    tableView.frame = view.bounds
    headerBlur.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 60)
    titleLabel.sizeToFit()
    titleLabel.center = CGPoint(x: headerBlur.bounds.midX, y: headerBlur.bounds.maxY - 20)
    closeButton.frame = CGRect(x: headerBlur.bounds.width - 44, y: headerBlur.bounds.maxY - 34, width: 28, height: 28)
  }
  
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    if tab == .media {
      return Int(ceil(Double(rows.count) / 3.0))
    }
    return rows.count
  }
  
  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    if tab == .media {
      let cols: CGFloat = 3.0
      let padding: CGFloat = 16.0
      let gap: CGFloat = 2.0
      let avail = max(0.0, tableView.bounds.width - padding * 2.0 - gap * (cols - 1))
      let itemHeight = floor(avail / cols)
      return itemHeight + gap
    } else if tab == .voice || tab == .gifs {
      return 72.0
    }
    return 68.0
  }
  
  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let isLast = indexPath.row == tableView.numberOfRows(inSection: 0) - 1
    
    if tab == .media {
      guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatProfileMediaGridRowCell.reuseIdentifier, for: indexPath) as? ChatProfileMediaGridRowCell else { return UITableViewCell() }
      var items: [(url: String?, isVideo: Bool, thumbnailBase64: String?)] = []
      let startIndex = indexPath.row * 3
      for i in 0..<3 {
        let absIndex = startIndex + i
        if absIndex < rows.count, let r = rows[absIndex] as? ChatProfileRow {
          items.append((url: r.mediaUrl, isVideo: r.type == "video", thumbnailBase64: r.thumbnailBase64))
        }
      }
      cell.configure(items: items, startIndex: startIndex, placeholderTintColor: .gray, placeholderBackgroundColor: .darkGray)
      cell.onMediaTapped = { [weak self] index in
        guard let self = self, index < self.rows.count, let r = self.rows[index] as? ChatProfileRow else { return }
        self.onContentPressed?(["type": "profileContentPressed", "tab": self.tab.rawValue, "messageId": r.messageId, "url": r.mediaUrl ?? ""])
      }
      return cell
    }
    
    let rowObj = rows[indexPath.row]
    var r: ChatProfileRow? = rowObj as? ChatProfileRow
    if tab == .links, let linkItem = rowObj as? ChatProfileLinkItem { r = linkItem.row }
    guard let row = r else { return UITableViewCell() }
    
    if tab == .voice {
      guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatProfileVoiceContentCell.reuseIdentifier, for: indexPath) as? ChatProfileVoiceContentCell else { return UITableViewCell() }
      cell.configure(title: row.fileName ?? "Voice message", subtitle: "Voice", row: row, titleColor: themeIsDark ? .white : .black, subtitleColor: .gray, accentColor: .systemBlue)
      VoiceBubblePlaybackCoordinator.shared.bind(cell: cell, messageId: row.messageId, mediaURL: row.mediaUrl, mediaKey: row.mediaKey, fileName: row.fileName)
      return cell
    }
    
    guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatProfileListRowCell.reuseIdentifier, for: indexPath) as? ChatProfileListRowCell else { return UITableViewCell() }
    cell.rowNode.configure(title: row.fileName ?? "Item", subtitle: "", value: "", showsSeparator: !isLast, iconName: "doc", iconTintColor: .systemBlue, iconBackgroundColor: .clear, showsChevron: false)
    cell.backgroundColor = .clear
    return cell
  }
  
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard tab != .media else { return }
    let rowObj = rows[indexPath.row]
    var r: ChatProfileRow? = rowObj as? ChatProfileRow
    if tab == .links, let linkItem = rowObj as? ChatProfileLinkItem { r = linkItem.row }
    guard let row = r else { return }
    
    if tab == .voice {
      if let cell = tableView.cellForRow(at: indexPath) as? VoicePlayableCell {
        VoiceBubblePlaybackCoordinator.shared.toggle(cell: cell, messageId: row.messageId, mediaURL: row.mediaUrl, mediaKey: row.mediaKey, fileName: row.fileName)
      }
      return
    }
    
    var payload: [String: Any] = ["type": "profileContentPressed", "tab": tab.rawValue, "messageId": row.messageId]
    if tab == .links, let linkItem = rowObj as? ChatProfileLinkItem { payload["url"] = linkItem.url }
    else if let mediaUrl = row.mediaUrl, !mediaUrl.isEmpty { payload["url"] = mediaUrl }
    
    onContentPressed?(payload)
  }
}
