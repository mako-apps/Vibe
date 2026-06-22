import UIKit

struct AgentInboxItem {
  let id: String
  let eventType: String?
  let source: String?
  let title: String
  let body: String
  let priority: String?
  let occurredAt: Date?
  let payload: [String: Any]
  let threadTitle: String?
  let status: String?

  init(row: ChatListRow) {
    let split = Self.splitTitleAndBody(row.text, eventType: row.eventType)
    id = row.messageId ?? UUID().uuidString
    eventType = row.eventType
    source = nil
    title = split.title
    body = split.body
    priority = row.eventPriority
    occurredAt = Self.date(from: row.timestamp)
    payload = [:]
    threadTitle = nil
    status = nil
  }

  init?(raw: [String: Any]) {
    guard let id = Self.string(raw["id"]) else { return nil }
    let eventType = Self.string(raw["eventType"] ?? raw["event_type"])
    let rawTitle = Self.string(raw["title"] ?? raw["threadTitle"] ?? raw["thread_title"])
    let rawText = Self.string(raw["text"]) ?? ""
    let split = Self.splitTitleAndBody(rawText, eventType: eventType)

    self.id = id
    self.eventType = eventType
    source = Self.string(raw["source"])
    title = rawTitle ?? split.title
    body = split.body.isEmpty && rawTitle != nil ? rawText : split.body
    priority = Self.string(raw["priority"])
    occurredAt = Self.date(from: raw["occurredAt"] ?? raw["occurred_at"])
    payload = raw["payload"] as? [String: Any] ?? [:]
    threadTitle = Self.string(raw["threadTitle"] ?? raw["thread_title"])
    status = Self.string(raw["status"])
  }

  var detailText: String {
    var sections: [String] = []
    if !body.isEmpty { sections.append(body) }

    let metadata = [
      eventType.map { "Event: \($0)" },
      source.map { "Source: \($0)" },
      status.map { "Status: \($0)" },
      threadTitle.map { "Thread: \($0)" },
    ].compactMap { $0 }
    if !metadata.isEmpty { sections.append(metadata.joined(separator: "\n")) }

    if !payload.isEmpty,
      JSONSerialization.isValidJSONObject(payload),
      let data = try? JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
      ),
      let text = String(data: data, encoding: .utf8)
    {
      sections.append("Payload\n\(text)")
    }

    return sections.joined(separator: "\n\n")
  }

  private static func splitTitleAndBody(
    _ text: String,
    eventType: String?
  ) -> (title: String, body: String) {
    let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = raw.components(separatedBy: "\n")
    if let first = lines.first, first.hasPrefix("#") {
      var title = first
      while title.hasPrefix("#") { title.removeFirst() }
      let body = lines.dropFirst().joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return (title.trimmingCharacters(in: .whitespaces), body)
    }
    return (humanizeEventType(eventType) ?? "Notification", raw)
  }

  private static func humanizeEventType(_ eventType: String?) -> String? {
    guard let eventType, !eventType.isEmpty else { return nil }
    let spaced =
      eventType
      .replacingOccurrences(of: ".", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .trimmingCharacters(in: .whitespaces)
    return spaced.isEmpty ? nil : spaced.capitalized
  }

  private static func string(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func date(from value: Any?) -> Date? {
    if let number = value as? NSNumber {
      let raw = number.doubleValue
      return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000.0 : raw)
    }
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if let raw = Double(trimmed) {
      return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000.0 : raw)
    }
    return ISO8601DateFormatter().date(from: trimmed)
  }
}

struct AgentInboxPage {
  let items: [AgentInboxItem]
  let total: Int
  let hasMore: Bool
}

enum AgentInboxAPI {
  static func loadPage(
    agentID: String,
    config: AppSessionConfig,
    limit: Int = 200,
    offset: Int = 0
  ) async throws -> AgentInboxPage {
    var components = URLComponents(
      url:
        config.apiBaseURL
        .appendingPathComponent("api")
        .appendingPathComponent("agents")
        .appendingPathComponent(agentID)
        .appendingPathComponent("events"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "limit", value: String(limit)),
      URLQueryItem(name: "offset", value: String(offset)),
    ]
    guard let url = components?.url else { throw URLError(.badURL) }

    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, response) = try await ChatPhoenixClient.makePinnedURLSession().data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw URLError(.cannotParseResponse)
    }

    let items =
      (root["items"] as? [[String: Any]] ?? [])
      .compactMap(AgentInboxItem.init(raw:))
    let total = (root["total"] as? NSNumber)?.intValue ?? items.count
    let hasMore = (root["hasMore"] as? Bool) ?? (offset + items.count < total)
    return AgentInboxPage(items: items, total: total, hasMore: hasMore)
  }

  static func loadAll(agentID: String, config: AppSessionConfig) async throws
    -> [AgentInboxItem]
  {
    let pageSize = 200
    var offset = 0
    var allItems: [AgentInboxItem] = []

    while true {
      let page = try await loadPage(
        agentID: agentID,
        config: config,
        limit: pageSize,
        offset: offset
      )
      allItems.append(contentsOf: page.items)
      offset += page.items.count
      if !page.hasMore || page.items.isEmpty { break }
    }

    return allItems
  }
}

/// Durable list of an agent's received events. Chat rows are used immediately as
/// an offline fallback, then replaced by the owner-authenticated `agent_events`
/// history so batched events without chat bubbles are still visible.
final class AgentInboxViewController: UIViewController {
  private var items: [AgentInboxItem]
  private let agentTitle: String
  private let agentID: String?
  private let config: AppSessionConfig?
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let emptyLabel = UILabel()
  private let refreshControl = UIRefreshControl()
  private var loadTask: Task<Void, Never>?

  init(
    rows: [ChatListRow],
    agentTitle: String,
    agentID: String?,
    config: AppSessionConfig?
  ) {
    items = rows.reversed().map(AgentInboxItem.init(row:))
    self.agentTitle = agentTitle
    self.agentID = agentID
    self.config = config
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    loadTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    navigationItem.prompt = agentTitle
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done,
      target: self,
      action: #selector(handleDone)
    )

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 84
    tableView.backgroundColor = .systemBackground
    tableView.register(AgentInboxCell.self, forCellReuseIdentifier: AgentInboxCell.reuseID)
    refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    tableView.refreshControl = refreshControl
    view.addSubview(tableView)

    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    emptyLabel.textColor = .secondaryLabel
    emptyLabel.font = .systemFont(ofSize: 15, weight: .regular)
    emptyLabel.textAlignment = .center
    view.addSubview(emptyLabel)

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    updateState(isLoading: agentID != nil && config != nil)
    loadPersistentEvents()
  }

  @objc private func handleDone() {
    dismiss(animated: true)
  }

  @objc private func handleRefresh() {
    loadPersistentEvents()
  }

  private func loadPersistentEvents() {
    guard let agentID, let config else {
      refreshControl.endRefreshing()
      updateState(isLoading: false)
      return
    }

    loadTask?.cancel()
    loadTask = Task { [weak self] in
      do {
        let loaded = try await AgentInboxAPI.loadAll(agentID: agentID, config: config)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard let self else { return }
          self.items = loaded
          self.refreshControl.endRefreshing()
          self.tableView.reloadData()
          self.updateState(isLoading: false)
        }
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard let self else { return }
          self.refreshControl.endRefreshing()
          self.updateState(isLoading: false)
        }
      }
    }
  }

  private func updateState(isLoading: Bool) {
    title = items.isEmpty ? "Inbox" : "Inbox · \(items.count)"
    emptyLabel.text = isLoading ? "Loading received events…" : "No received events yet"
    emptyLabel.isHidden = !items.isEmpty
  }
}

extension AgentInboxViewController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    items.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell =
      tableView.dequeueReusableCell(withIdentifier: AgentInboxCell.reuseID, for: indexPath)
      as! AgentInboxCell
    cell.configure(with: items[indexPath.row])
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    navigationController?.pushViewController(
      AgentInboxDetailViewController(item: items[indexPath.row]),
      animated: true
    )
  }
}

private final class AgentInboxCell: UITableViewCell {
  static let reuseID = "AgentInboxCell"

  private let priorityDot = UIView()
  private let titleLabel = UILabel()
  private let bodyLabel = UILabel()
  private let timeLabel = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    accessoryType = .disclosureIndicator
    backgroundColor = .clear

    priorityDot.translatesAutoresizingMaskIntoConstraints = false
    priorityDot.layer.cornerRadius = 4
    priorityDot.clipsToBounds = true

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel.textColor = .label
    titleLabel.numberOfLines = 1

    timeLabel.translatesAutoresizingMaskIntoConstraints = false
    timeLabel.font = .systemFont(ofSize: 12, weight: .regular)
    timeLabel.textColor = .secondaryLabel
    timeLabel.textAlignment = .right
    timeLabel.setContentHuggingPriority(.required, for: .horizontal)
    timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    bodyLabel.translatesAutoresizingMaskIntoConstraints = false
    bodyLabel.font = .systemFont(ofSize: 14, weight: .regular)
    bodyLabel.textColor = .secondaryLabel
    bodyLabel.numberOfLines = 3

    contentView.addSubview(priorityDot)
    contentView.addSubview(titleLabel)
    contentView.addSubview(timeLabel)
    contentView.addSubview(bodyLabel)

    NSLayoutConstraint.activate([
      priorityDot.widthAnchor.constraint(equalToConstant: 8),
      priorityDot.heightAnchor.constraint(equalToConstant: 8),
      priorityDot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      priorityDot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

      titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
      titleLabel.leadingAnchor.constraint(equalTo: priorityDot.trailingAnchor, constant: 10),

      timeLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: titleLabel.trailingAnchor,
        constant: 8
      ),
      timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
      timeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

      bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
      bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      bodyLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
      bodyLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with item: AgentInboxItem) {
    titleLabel.text = item.title
    bodyLabel.text = item.body
    bodyLabel.isHidden = item.body.isEmpty
    timeLabel.text = Self.relativeTime(from: item.occurredAt)
    priorityDot.backgroundColor = Self.priorityColor(item.priority)
  }

  private static func priorityColor(_ priority: String?) -> UIColor {
    switch priority?.lowercased() {
    case "urgent": return .systemRed
    case "high": return .systemOrange
    default: return .systemBlue
    }
  }

  private static func relativeTime(from date: Date?) -> String {
    guard let date else { return "" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

private final class AgentInboxDetailViewController: UIViewController {
  private let item: AgentInboxItem
  private let textView = UITextView()

  init(item: AgentInboxItem) {
    self.item = item
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = item.title
    view.backgroundColor = .systemBackground

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.isSelectable = true
    textView.alwaysBounceVertical = true
    textView.backgroundColor = .clear
    textView.textColor = .label
    textView.font = .systemFont(ofSize: 15)
    textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 24, right: 16)
    textView.text = item.detailText
    view.addSubview(textView)

    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.topAnchor.constraint(equalTo: view.topAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }
}
