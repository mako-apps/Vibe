import UIKit

final class ChatGroupMembersViewController: UIViewController {
  struct MemberItem {
    let userId: String
    let name: String
    let roleLabel: String
    let isAdmin: Bool
  }

  var chatId: String = ""
  var members: [MemberItem] = []
  var canAddMembers: Bool = false
  var onAddMembers: (() -> Void)?
  var onMemberSelected: ((MemberItem) -> Void)?

  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let emptyLabel = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    setup()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    NSLog(
      "[WhoAmI] MembersUIKit.viewWillAppear chatId=%@ members=%d canAdd=%@",
      chatId.isEmpty ? "<none>" : String(chatId.prefix(12)),
      members.count,
      canAddMembers ? "Y" : "N"
    )
    reloadEmptyState()
    tableView.reloadData()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    tableView.frame = view.bounds
    emptyLabel.frame = CGRect(x: 24, y: 160, width: view.bounds.width - 48, height: 40)
  }

  func applyMembers(_ next: [MemberItem]) {
    members = next
    reloadEmptyState()
    tableView.reloadData()
  }

  private func setup() {
    title = "Members"
    view.backgroundColor = .black
    navigationItem.largeTitleDisplayMode = .never

    tableView.dataSource = self
    tableView.delegate = self
    tableView.backgroundColor = .black
    tableView.separatorStyle = .none
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "member_cell")
    tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
    view.addSubview(tableView)

    emptyLabel.textAlignment = .center
    emptyLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
    emptyLabel.textColor = UIColor.white.withAlphaComponent(0.55)
    emptyLabel.text = "No members available"
    emptyLabel.numberOfLines = 0
    view.addSubview(emptyLabel)
    reloadEmptyState()

    if canAddMembers {
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "person.badge.plus"),
        style: .plain,
        target: self,
        action: #selector(addMembersTapped)
      )
      navigationItem.rightBarButtonItem?.accessibilityLabel = "Add Members"
    }

    // Match the dark profile chrome.
    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = .black
    appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
    navigationItem.standardAppearance = appearance
    navigationItem.scrollEdgeAppearance = appearance
    navigationItem.compactAppearance = appearance
    navigationController?.navigationBar.tintColor = .white
  }

  private func reloadEmptyState() {
    emptyLabel.isHidden = !members.isEmpty
  }

  @objc private func addMembersTapped() {
    onAddMembers?()
  }
}

extension ChatGroupMembersViewController: UITableViewDataSource, UITableViewDelegate {
  func numberOfSections(in tableView: UITableView) -> Int {
    canAddMembers ? 2 : 1
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    if section == 0 { return max(members.count, members.isEmpty ? 1 : 0) }
    return 1
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    if section == 0 {
      if members.isEmpty { return "Members" }
      return "\(members.count) member\(members.count == 1 ? "" : "s")"
    }
    return nil
  }

  func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
    guard let header = view as? UITableViewHeaderFooterView else { return }
    header.textLabel?.textColor = UIColor.white.withAlphaComponent(0.55)
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "member_cell", for: indexPath)
    var content = UIListContentConfiguration.subtitleCell()

    if indexPath.section == 1 {
      content.text = "Add Members"
      content.secondaryText = nil
      content.textProperties.font = UIFont.systemFont(ofSize: 16, weight: .medium)
      content.textProperties.color = .systemBlue
      content.image = UIImage(systemName: "person.badge.plus")
      content.imageProperties.tintColor = .systemBlue
      content.imageToTextPadding = 12
      cell.selectionStyle = .default
    } else if members.isEmpty {
      content.text = "No members yet"
      content.secondaryText = "Pull to refresh the home list, then reopen."
      content.textProperties.font = UIFont.systemFont(ofSize: 15, weight: .medium)
      content.textProperties.color = UIColor.white.withAlphaComponent(0.7)
      content.secondaryTextProperties.color = UIColor.white.withAlphaComponent(0.45)
      content.image = UIImage(systemName: "person.3")
      content.imageProperties.tintColor = UIColor.white.withAlphaComponent(0.45)
      cell.selectionStyle = .none
    } else {
      let item = members[indexPath.row]
      content.text = item.name
      content.secondaryText = item.roleLabel
      content.textProperties.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
      content.textProperties.color = .white
      content.secondaryTextProperties.font = UIFont.systemFont(ofSize: 13, weight: .medium)
      content.secondaryTextProperties.color = UIColor.white.withAlphaComponent(0.55)
      content.image = UIImage(systemName: item.isAdmin ? "star.circle.fill" : "person.circle")
      content.imageProperties.tintColor = item.isAdmin ? .systemYellow : UIColor.white.withAlphaComponent(0.55)
      content.imageToTextPadding = 12
      cell.selectionStyle = .default
      cell.accessoryType = .disclosureIndicator
    }

    cell.contentConfiguration = content
    cell.backgroundColor = .clear
    var bg = UIBackgroundConfiguration.listGroupedCell()
    bg.backgroundColor = UIColor(white: 0.14, alpha: 1.0)
    bg.cornerRadius = 14
    cell.backgroundConfiguration = bg
    cell.tintColor = UIColor.white.withAlphaComponent(0.35)
    return cell
  }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    62
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 1 {
      onAddMembers?()
      return
    }
    guard !members.isEmpty, indexPath.row < members.count else { return }
    onMemberSelected?(members[indexPath.row])
  }
}
