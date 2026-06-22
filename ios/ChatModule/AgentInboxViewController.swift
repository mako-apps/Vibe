import UIKit

/// Dedicated, focused list of an agent's event notifications. Presented when the
/// user taps the Inbox banner in an inbox-mode (batched_summary) agent chat, so
/// notifications stay out of the conversation transcript but remain one tap away.
final class AgentInboxViewController: UIViewController {
  private let items: [ChatListRow]
  private let agentTitle: String
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let emptyLabel = UILabel()

  /// `rows` are passed in transcript order (oldest first); the inbox shows the
  /// newest notification at the top.
  init(rows: [ChatListRow], agentTitle: String) {
    self.items = rows.reversed()
    self.agentTitle = agentTitle
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Inbox"
    navigationItem.prompt = agentTitle
    view.backgroundColor = .systemBackground
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .done, target: self, action: #selector(handleDone))

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 84
    tableView.backgroundColor = .systemBackground
    tableView.register(AgentInboxCell.self, forCellReuseIdentifier: AgentInboxCell.reuseId)
    view.addSubview(tableView)

    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    emptyLabel.text = "No notifications yet"
    emptyLabel.textColor = .secondaryLabel
    emptyLabel.font = .systemFont(ofSize: 15, weight: .regular)
    emptyLabel.textAlignment = .center
    emptyLabel.isHidden = !items.isEmpty
    view.addSubview(emptyLabel)

    NSLayoutConstraint.activate([
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
  }

  @objc private func handleDone() {
    dismiss(animated: true)
  }
}

extension AgentInboxViewController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    items.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell =
      tableView.dequeueReusableCell(withIdentifier: AgentInboxCell.reuseId, for: indexPath)
      as! AgentInboxCell
    cell.configure(with: items[indexPath.row])
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
  }
}

private final class AgentInboxCell: UITableViewCell {
  static let reuseId = "AgentInboxCell"

  private let priorityDot = UIView()
  private let titleLabel = UILabel()
  private let bodyLabel = UILabel()
  private let timeLabel = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
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
        greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
      timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      timeLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

      bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
      bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      bodyLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      bodyLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with row: ChatListRow) {
    let (title, body) = Self.splitTitleAndBody(row)
    titleLabel.text = title
    bodyLabel.text = body
    bodyLabel.isHidden = body.isEmpty
    timeLabel.text = Self.relativeTime(from: row.timestamp)
    priorityDot.backgroundColor = Self.priorityColor(row.eventPriority)
  }

  private static func priorityColor(_ priority: String?) -> UIColor {
    switch priority?.lowercased() {
    case "urgent": return .systemRed
    case "high": return .systemOrange
    default: return .systemBlue
    }
  }

  /// Event messages carry a leading markdown heading (`# Title`) added server-side;
  /// surface that as the cell title and the remainder as the body. Falls back to a
  /// humanized event type when no heading is present.
  private static func splitTitleAndBody(_ row: ChatListRow) -> (String, String) {
    let raw = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = raw.components(separatedBy: "\n")
    if let first = lines.first, first.hasPrefix("#") {
      var title = first
      while title.hasPrefix("#") { title.removeFirst() }
      let body = lines.dropFirst().joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return (title.trimmingCharacters(in: .whitespaces), body)
    }
    let title = humanizeEventType(row.eventType) ?? "Notification"
    return (title, raw)
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

  private static func relativeTime(from timestamp: String) -> String {
    let trimmed = timestamp.trimmingCharacters(in: .whitespaces)
    guard let millis = Double(trimmed) else { return "" }
    let date = Date(timeIntervalSince1970: millis / 1000.0)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}
