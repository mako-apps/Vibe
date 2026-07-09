import CryptoKit
import Foundation
import Network

/// End-to-end decryption for the agent runtime payload (file diffs / patches).
///
/// The bridge encrypts the runtime blob with a 32-byte key shared only with this
/// phone — handed over during pairing through the QR, which the Vibe server never
/// sees. We keep that key in the Keychain and decrypt locally so the
/// "files changed" card can render. The server only ever holds opaque ciphertext.
enum AgentRuntimeCrypto {
  /// Legacy Keychain account for the shared runtime key (base64 of 32 bytes).
  static let keychainAccount = "agentBridge.runtimeKey"
  private static let scopedKeychainAccountPrefix = "agentBridge.runtimeKey.v2"
  private static let blobPrefix = "arte1"

  // The key is read on a hot path (every agent row with an encrypted blob), so
  // cache it in memory and only fall back to the Keychain on a cold miss.
  private static let cacheQueue = DispatchQueue(label: "agentRuntimeCrypto.key")
  private static var cachedKey: Data?
  private static var cachedKeychainAccount: String?
  private static var cacheLoaded = false

  private static func keyData() -> Data? {
    let account = activeKeychainAccount()
    return cacheQueue.sync {
      if !cacheLoaded || cachedKeychainAccount != account {
        cacheLoaded = true
        cachedKeychainAccount = account
        cachedKey = loadKey(account: account)
      }
      return cachedKey
    }
  }

  /// Tail of the active keychain account, for diagnostics only (never logs the key).
  static func debugActiveAccountTail() -> String {
    String(activeKeychainAccount().suffix(12))
  }

  /// Persist a runtime key (base64, 32 bytes) handed over by the bridge.
  @discardableResult
  static func storeKey(_ base64Key: String) -> Bool {
    let trimmed = base64Key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: trimmed), data.count == 32 else {
      NSLog(
        "[KeySync] storeKey reject: decoded=\(Data(base64Encoded: trimmed)?.count ?? -1) bytes (need 32), b64Len=\(trimmed.count)"
      )
      return false
    }
    let account = activeKeychainAccount()
    let ok = SecureKeyStore.shared.storeSecret(key: account, value: trimmed)
    NSLog("[KeySync] storeSecret ok=\(ok) accountTail=\(String(account.suffix(12))) scoped=\(currentScopedKeychainAccount() != nil)")
    if ok {
      if account != keychainAccount {
        SecureKeyStore.shared.deleteSecret(key: keychainAccount)
      }
      cacheQueue.sync {
        cachedKey = data
        cachedKeychainAccount = account
        cacheLoaded = true
      }
    }
    return ok
  }

  static var hasKey: Bool { keyData() != nil }

  /// Drop the stored runtime key for the active account. Used by repair/reset flows
  /// so a stale Keychain value cannot keep decrypting with an old desktop key.
  static func clearStoredKeyForCurrentSession() {
    let account = activeKeychainAccount()
    SecureKeyStore.shared.deleteSecret(key: account)
    if account != keychainAccount {
      SecureKeyStore.shared.deleteSecret(key: keychainAccount)
    }
    cacheQueue.sync {
      cachedKey = nil
      cachedKeychainAccount = account
      cacheLoaded = true
    }
  }

  private static func activeKeychainAccount() -> String {
    currentScopedKeychainAccount() ?? keychainAccount
  }

  private static func currentScopedKeychainAccount() -> String? {
    guard let config = AppSessionConfig.current else { return nil }
    let server = AgentPairingService.serverBase(config: config)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let userID = config.userID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !server.isEmpty, !userID.isEmpty else { return nil }
    let digest = SHA256.hash(data: Data("\(server)|\(userID)".utf8))
    return "\(scopedKeychainAccountPrefix).\(base64urlEncode(Data(digest)))"
  }

  private static func loadKey(account: String) -> Data? {
    guard let b64 = SecureKeyStore.shared.retrieveSecret(key: account),
      let data = Data(base64Encoded: b64), data.count == 32
    else { return nil }
    return data
  }

  /// Extract a runtime key from a scanned QR payload, if one is present: the
  /// dedicated `vibegram-rk:<b64>` sync QR, or the `#<b64>` fragment of a
  /// `vibegram-pair:<id>#<b64>` pairing QR.
  static func runtimeKey(fromScanned payload: String) -> String? {
    let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("vibegram-rk:") {
      let key = String(trimmed.dropFirst("vibegram-rk:".count))
      return key.isEmpty ? nil : key
    }
    if trimmed.hasPrefix("vibegram-pair:"), let hash = trimmed.firstIndex(of: "#") {
      let key = String(trimmed[trimmed.index(after: hash)...])
      return key.isEmpty ? nil : key
    }
    return nil
  }

  /// Encrypt a JSON object into an `arte1.<iv>.<ct>.<tag>` blob with the shared
  /// pairing key — the same envelope the bridge produces, so the daemon can decrypt
  /// it. Used to seal phone→computer payloads (e.g. image attachments) so the server
  /// only ever relays an opaque blob. Returns nil when there's no key.
  static func encrypt(_ object: [String: Any]) -> String? {
    guard let key = keyData(),
      let plaintext = try? JSONSerialization.data(withJSONObject: object)
    else { return nil }
    do {
      let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key))
      return [
        blobPrefix,
        base64urlEncode(Data(sealed.nonce)),
        base64urlEncode(sealed.ciphertext),
        base64urlEncode(sealed.tag),
      ].joined(separator: ".")
    } catch {
      return nil
    }
  }

  /// Decrypt an `arte1.<iv>.<ct>.<tag>` blob into the runtime dictionary. Returns
  /// nil when there's no key, the envelope is malformed, or authentication fails.
  static func decrypt(_ blob: Any?) -> [String: Any]? {
    guard let blob = blob as? String else { return nil }
    let parts = blob.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 4, parts[0] == blobPrefix else { return nil }
    guard let key = keyData(),
      let iv = base64urlDecode(parts[1]),
      let ct = base64urlDecode(parts[2]),
      let tag = base64urlDecode(parts[3])
    else { return nil }
    do {
      let box = try AES.GCM.SealedBox(
        nonce: try AES.GCM.Nonce(data: iv), ciphertext: ct, tag: tag)
      let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key))
      return try JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
    } catch {
      return nil
    }
  }

  private static func base64urlEncode(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func base64urlDecode(_ value: String) -> Data? {
    var str = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    let remainder = str.count % 4
    if remainder > 0 { str += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: str)
  }
}

struct AgentBridgeRepository: Hashable, Identifiable {
  let id: String
  let name: String
  let path: String
  let cwd: String
  let source: String?
  let isGitRepository: Bool
}

struct AgentBridgeDevice: Hashable {
  let label: String
  let cwd: String?
  let repositories: [AgentBridgeRepository]
  let runningTasks: [AgentBridgeRunningTask]
}

struct AgentBridgeRunningTask: Hashable, Identifiable {
  let provider: String
  let chatId: String
  let taskId: String
  let sessionId: String?
  let topic: String
  let repoId: String?
  let repoName: String?
  let project: String?
  let projectName: String?
  let cwd: String?
  let workMode: String?
  let model: String?
  let startedAt: String?

  var id: String {
    if let sessionId, !sessionId.isEmpty { return sessionId }
    return taskId
  }
}

enum AgentBridgeWorkMode: String, CaseIterable, Identifiable {
  /// Research & propose a plan, then request approval on your phone before any
  /// edits run. Drives the plan-file → ExitPlanMode approval round-trip.
  case plan = "plan"
  /// Live per-action approval routed to your phone (permission-prompt round-trip).
  case ask = "ask"
  /// Analyse & propose only — never changes files.
  case readOnly = "read_only"
  /// Let the provider auto-run low-risk commands while the bridge keeps destructive
  /// commands on the deny/approval side.
  case askAuto = "ask_auto"
  /// Auto-approve edits + sandboxed command execution.
  case allowEdits = "allow_edits"
  /// No sandbox — the agent can run anything in the selected repo.
  case fullAccess = "full_access"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .plan: return "Plan"
    case .ask: return "Ask"
    case .readOnly: return "Read"
    case .askAuto: return "Safe Auto"
    case .allowEdits: return "Auto"
    case .fullAccess: return "Full"
    }
  }

  var subtitle: String {
    switch self {
    case .plan: return "Propose a plan, approve on your phone before editing"
    case .ask: return "Approve each change or command from your phone"
    case .readOnly: return "Read & propose only — never changes files"
    case .askAuto: return "Auto-run low-risk work; block destructive commands"
    case .allowEdits: return "Auto-approve edits & sandboxed commands"
    case .fullAccess: return "No sandbox — can run anything (use with care)"
    }
  }

  var icon: String {
    switch self {
    case .plan: return "list.bullet.clipboard"
    case .ask: return "hand.raised"
    case .readOnly: return "eye"
    case .askAuto: return "shield.lefthalf.filled"
    case .allowEdits: return "pencil"
    case .fullAccess: return "bolt"
    }
  }

  /// Whether this mode runs as propose-only / plan-style (no autonomous edits).
  /// Drives the plan-mode badge on the phone.
  var isPlanLike: Bool {
    switch self {
    case .plan, .readOnly: return true
    case .ask, .askAuto, .allowEdits, .fullAccess: return false
    }
  }
}

enum AgentBridgeIntelligenceLevel: String, CaseIterable, Identifiable {
  case low
  case medium
  case high
  case extraHigh = "extra_high"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .low: return "Low"
    case .medium: return "Medium"
    case .high: return "High"
    case .extraHigh: return "Extra High"
    }
  }

  var claudeEffort: String {
    switch self {
    case .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    case .extraHigh: return "xhigh"
    }
  }

  var codexEffort: String {
    switch self {
    case .low: return "low"
    case .medium: return "medium"
    case .high, .extraHigh: return "high"
    }
  }
}

enum AgentBridgeSpeedMode: String, CaseIterable, Identifiable {
  case fast
  case standard
  case careful

  var id: String { rawValue }

  var title: String {
    switch self {
    case .fast: return "Fast"
    case .standard: return "Standard"
    case .careful: return "Careful"
    }
  }
}

struct AgentBridgeRunOptions: Equatable {
  let model: String?
  let advisor: String?
  let intelligence: AgentBridgeIntelligenceLevel
  let speed: AgentBridgeSpeedMode

  func payload(provider: String) -> [String: Any] {
    var out: [String: Any] = [
      "agentBridgeIntelligence": intelligence.rawValue,
      "agentBridgeSpeed": speed.rawValue,
      "agentBridgeReasoningEffort": Self.effectiveEffort(
        provider: provider,
        intelligence: intelligence,
        speed: speed
      ),
    ]
    if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      out["agentBridgeModel"] = model
    }
    if provider.lowercased() == "claude",
      let advisor, !advisor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      out["agentBridgeAdvisor"] = advisor
    }
    return out
  }

  static func effectiveEffort(
    provider: String,
    intelligence: AgentBridgeIntelligenceLevel,
    speed: AgentBridgeSpeedMode
  ) -> String {
    let ladder = provider.lowercased() == "claude"
      ? ["low", "medium", "high", "xhigh"]
      : ["low", "medium", "high"]
    let base = provider.lowercased() == "claude" ? intelligence.claudeEffort : intelligence.codexEffort
    let baseIndex = ladder.firstIndex(of: base) ?? min(1, ladder.count - 1)
    let offset: Int
    switch speed {
    case .fast: offset = -1
    case .standard: offset = 0
    case .careful: offset = 1
    }
    return ladder[min(max(baseIndex + offset, 0), ladder.count - 1)]
  }
}

/// Whether a paired computer (the `vibe-bridge` daemon) is connected right now.
struct AgentBridgeStatus {
  /// A daemon is currently online (Presence on `bridge:<user_id>`).
  let connected: Bool
  /// The account has at least one non-revoked bridge token on record.
  let paired: Bool
  /// Flattened list of working trees advertised by the connected bridge daemon.
  let repositories: [AgentBridgeRepository]
  /// Connected bridge devices. Usually one computer for now.
  let devices: [AgentBridgeDevice]
  /// Flattened list of tasks currently running on connected bridge daemons.
  let runningTasks: [AgentBridgeRunningTask]

  static let disconnected = AgentBridgeStatus(
    connected: false,
    paired: false,
    repositories: [],
    devices: [],
    runningTasks: []
  )
}

// MARK: - Default chat view preference (Chat vs Agent runtime) for Claude/Codex agents

/// Whether opening an agent's DM conversation lands in the classic chat
/// (bubbles + wallpaper) or jumps straight to the full-page agent runtime view.
enum AgentBridgeDefaultView: String, CaseIterable, Identifiable {
  case chat
  case agent
  case visual

  var id: String { rawValue }

  var title: String {
    switch self {
    case .chat: return "Default chat"
    case .agent: return "Engine view"
    case .visual: return "Visual workspace"
    }
  }

  var subtitle: String {
    switch self {
    case .chat: return "Open in the normal message thread"
    case .agent: return "Open directly in the agent runtime view"
    case .visual: return "Open in the live file, command, and problem workspace"
    }
  }
}

enum AgentBridgeSelectionStore {
  static let didChangeNotification = Notification.Name("AgentBridgeSelectionStoreDidChange")

  private static let repositoryKey = "agentBridge.selectedRepository"
  private static let workModeKey = "agentBridge.workMode"
  private static let intelligenceKey = "agentBridge.intelligence"
  private static let speedKey = "agentBridge.speed"
  private static func modelKey(_ provider: String) -> String {
    "agentBridge.model.\(provider.lowercased())"
  }
  private static func advisorKey(_ provider: String) -> String {
    "agentBridge.advisor.\(provider.lowercased())"
  }
  static func selectedRepository() -> AgentBridgeRepository? {
    guard
      let data = UserDefaults.standard.data(forKey: repositoryKey),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = normalizedString(object["id"]),
      let path = normalizedString(object["path"])
    else {
      return nil
    }

    return AgentBridgeRepository(
      id: id,
      name: normalizedString(object["name"]) ?? URL(fileURLWithPath: path).lastPathComponent,
      path: path,
      cwd: normalizedString(object["cwd"]) ?? path,
      source: normalizedString(object["source"]),
      isGitRepository: boolValue(object["git"])
    )
  }

  static func select(_ repository: AgentBridgeRepository) {
    var object: [String: Any] = [
      "id": repository.id,
      "name": repository.name,
      "path": repository.path,
      "cwd": repository.cwd,
      "git": repository.isGitRepository,
    ]
    if let source = repository.source {
      object["source"] = source
    }
    if let data = try? JSONSerialization.data(withJSONObject: object) {
      UserDefaults.standard.set(data, forKey: repositoryKey)
      NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
  }

  static func selectedWorkMode() -> AgentBridgeWorkMode {
    // Default is Safe Auto (not Read): the old read_only default silently ran every
    // message in claude plan permission mode ("always plan mode" bug). Plan is now
    // an explicit, deliberately-chosen mode.
    let raw = UserDefaults.standard.string(forKey: workModeKey) ?? AgentBridgeWorkMode.askAuto.rawValue
    return AgentBridgeWorkMode(rawValue: raw) ?? .askAuto
  }

  static func setWorkMode(_ mode: AgentBridgeWorkMode) {
    UserDefaults.standard.set(mode.rawValue, forKey: workModeKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  static func selectedIntelligence() -> AgentBridgeIntelligenceLevel {
    let raw = UserDefaults.standard.string(forKey: intelligenceKey) ?? AgentBridgeIntelligenceLevel.low.rawValue
    return AgentBridgeIntelligenceLevel(rawValue: raw) ?? .low
  }

  static func setIntelligence(_ level: AgentBridgeIntelligenceLevel) {
    UserDefaults.standard.set(level.rawValue, forKey: intelligenceKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  static func selectedSpeed() -> AgentBridgeSpeedMode {
    let raw = UserDefaults.standard.string(forKey: speedKey) ?? AgentBridgeSpeedMode.standard.rawValue
    return AgentBridgeSpeedMode(rawValue: raw) ?? .standard
  }

  static func setSpeed(_ speed: AgentBridgeSpeedMode) {
    UserDefaults.standard.set(speed.rawValue, forKey: speedKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  static func selectedModel(provider: String) -> String? {
    guard let model = normalizedString(UserDefaults.standard.string(forKey: modelKey(provider))) else {
      return nil
    }
    let normalized = normalizedModel(provider: provider, model: model)
    if normalized != model {
      if let normalized {
        UserDefaults.standard.set(normalized, forKey: modelKey(provider))
      } else {
        UserDefaults.standard.removeObject(forKey: modelKey(provider))
      }
    }
    return normalized
  }

  static func setModel(provider: String, model: String?) {
    if let model = normalizedModel(provider: provider, model: normalizedString(model)) {
      UserDefaults.standard.set(model, forKey: modelKey(provider))
    } else {
      UserDefaults.standard.removeObject(forKey: modelKey(provider))
    }
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  static func selectedRunOptions(provider: String) -> AgentBridgeRunOptions {
    AgentBridgeRunOptions(
      model: selectedModel(provider: provider) ?? defaultRunModel(provider: provider),
      advisor: selectedAdvisor(provider: provider),
      intelligence: selectedIntelligence(),
      speed: selectedSpeed()
    )
  }

  // MARK: - Model catalog (shared title/menu source)

  /// Selectable models per provider. `value` is the canonical id stored/sent.
  static func modelChoices(provider: String) -> [(title: String, subtitle: String?, value: String)] {
    switch provider.lowercased() {
    case "claude":
      return [
        ("Haiku 4.5", "Fastest Claude model", "haiku"),
        ("Sonnet 5", "Balanced Claude model", "sonnet"),
        ("Opus 4.8", "Most capable Claude model", "opus"),
      ]
    case "grok":
      return [
        ("Grok 4.5", "Default Grok Build model", "grok-4.5"),
        ("Composer 2.5 Fast", "Faster Grok coding model", "grok-composer-2.5-fast"),
      ]
    default:
      return [
        ("GPT-5.5", nil, "gpt-5.5"),
        ("GPT-5.5 Pro", nil, "gpt-5.5-pro"),
        ("GPT-5.4", nil, "gpt-5.4"),
        ("GPT-5.2", nil, "gpt-5.2"),
        ("GPT-5", nil, "gpt-5"),
      ]
    }
  }

  static func selectedAdvisor(provider: String) -> String? {
    guard provider.lowercased() == "claude" else { return nil }
    guard let advisor = normalizedString(UserDefaults.standard.string(forKey: advisorKey(provider))) else {
      return defaultAdvisor(provider: provider)
    }
    if advisor.lowercased() == "off" { return nil }
    let normalized = normalizedAdvisor(provider: provider, advisor: advisor)
    if normalized != advisor {
      if let normalized {
        UserDefaults.standard.set(normalized, forKey: advisorKey(provider))
      } else {
        UserDefaults.standard.set("off", forKey: advisorKey(provider))
      }
    }
    return normalized
  }

  static func setAdvisor(provider: String, advisor: String?) {
    guard provider.lowercased() == "claude" else { return }
    if let advisor = normalizedString(advisor) {
      if let normalized = normalizedAdvisor(provider: provider, advisor: advisor) {
        UserDefaults.standard.set(normalized, forKey: advisorKey(provider))
      } else {
        UserDefaults.standard.set("off", forKey: advisorKey(provider))
      }
    } else {
      UserDefaults.standard.removeObject(forKey: advisorKey(provider))
    }
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  static func advisorChoices(provider: String) -> [(title: String, subtitle: String?, value: String?)] {
    guard provider.lowercased() == "claude" else { return [] }
    return [
      ("Fable 5", "Advisor for hard calls", "fable"),
      ("Off", "Use only the executor model", nil),
      ("Opus 4.8", "Legacy high-capability advisor", "opus"),
    ]
  }

  static func advisorTitle(provider: String, advisor: String?) -> String {
    guard let rawAdvisor = normalizedString(advisor) else { return "Off" }
    let canonical = normalizedAdvisor(provider: provider, advisor: rawAdvisor) ?? rawAdvisor.lowercased()
    if let match = advisorChoices(provider: provider).first(where: { $0.value == canonical }) {
      return match.title
    }
    return rawAdvisor
  }

  private static func defaultRunModel(provider: String) -> String? {
    switch provider.lowercased() {
    case "claude": return "sonnet"
    case "grok": return "grok-4.5"
    default: return nil
    }
  }

  private static func defaultAdvisor(provider: String) -> String? {
    provider.lowercased() == "claude" ? "fable" : nil
  }

  // MARK: - Slash command catalog (shared source for the input bar's tools sheet)

  struct SlashCommand: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let subtitle: String
  }

  struct SlashCommandGroup: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let commands: [SlashCommand]
  }

  /// Grouped Info / Tasks / Options slash commands for a provider. Selecting one drops
  /// "/name " into the composer so the user can add args and send (bridge info commands
  /// like /usage are answered in the glass overlay; task commands run as agent turns).
  static func slashCommandGroups(provider: String) -> [SlashCommandGroup] {
    let isCodex = provider.lowercased().contains("codex")
    let isGrok = provider.lowercased().contains("grok")
    let info: [SlashCommand] = [
      SlashCommand(name: "usage", subtitle: "Subscription limits + token usage"),
      SlashCommand(name: "status", subtitle: "Account, model, remaining usage"),
      SlashCommand(name: "commands", subtitle: "List available commands"),
      SlashCommand(name: "model", subtitle: "Show / switch model"),
      SlashCommand(name: "advisor", subtitle: "Show / switch Claude advisor"),
      SlashCommand(name: "compact", subtitle: "Summarize to free context"),
      SlashCommand(name: "doctor", subtitle: "Run the CLI health check"),
    ]
    let claudeTasks: [SlashCommand] = [
      SlashCommand(name: "code-review", subtitle: "Review the diff for bugs"),
      SlashCommand(name: "simplify", subtitle: "Cleanup-only review"),
      SlashCommand(name: "security-review", subtitle: "Scan changes for security issues"),
      SlashCommand(name: "debug", subtitle: "Investigate a failure"),
      SlashCommand(name: "init", subtitle: "Set up project memory"),
    ]
    let codexTasks: [SlashCommand] = [
      SlashCommand(name: "review", subtitle: "Review your working tree · desktop only"),
      SlashCommand(name: "init", subtitle: "Set up project memory · desktop only"),
    ]
    // Grok headless does not parse Claude/Codex slash tasks — keep the palette light.
    let grokTasks: [SlashCommand] = [
      SlashCommand(name: "init", subtitle: "Set up project memory"),
    ]
    let options: [SlashCommand] = [
      SlashCommand(name: "plan", subtitle: "Plan mode: research, don't edit"),
      SlashCommand(
        name: isCodex ? "fast" : "reasoning",
        subtitle: isCodex ? "Faster, lighter responses" : "Adjust thinking depth"),
    ]
    let tasks = isCodex ? codexTasks : (isGrok ? grokTasks : claudeTasks)
    return [
      SlashCommandGroup(title: "Info", commands: info),
      SlashCommandGroup(title: "Tasks", commands: tasks),
      SlashCommandGroup(title: "Options", commands: options),
    ]
  }

  /// "Use the model active in the local CLI session" fallback label.
  static func defaultModelTitle(provider: String) -> String {
    switch provider.lowercased() {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "grok": return "Grok"
    default: return provider.capitalized
    }
  }

  /// Human title for a model id (or the provider default when nil/unknown). Use this
  /// for the header so the displayed model matches whatever a loaded run reports.
  static func modelTitle(provider: String, model: String?) -> String {
    guard let rawModel = normalizedString(model) else { return defaultModelTitle(provider: provider) }
    // The bridge may report the CLI's fully-resolved model id (e.g.
    // "claude-sonnet-5-20260101"), not the bare alias — canonicalize first so it still
    // matches a catalog entry instead of falling through to the raw, ugly id string.
    let canonical = normalizedModel(provider: provider, model: rawModel) ?? rawModel.lowercased()
    if let match = modelChoices(provider: provider).first(where: { $0.value == canonical }) {
      return match.title
    }
    return rawModel
  }

  /// Public canonical-id resolver (e.g. "claude-3-5-sonnet" → "sonnet"). Returns nil
  /// for empty/unset; used to compare a loaded run's model against the menu choices.
  static func canonicalModel(provider: String, model: String?) -> String? {
    normalizedModel(provider: provider, model: normalizedString(model))
  }

  private static func normalizedModel(provider: String, model: String?) -> String? {
    guard let model = normalizedString(model) else { return nil }
    let normalized = model.lowercased().replacingOccurrences(of: "_", with: "-")
    switch provider.lowercased() {
    case "claude":
      if normalized.contains("haiku") { return "haiku" }
      if normalized.contains("sonnet") { return "sonnet" }
      if normalized.contains("opus") { return "opus" }
      return model
    case "grok":
      if normalized.contains("composer") { return "grok-composer-2.5-fast" }
      if normalized.contains("grok-4") || normalized == "grok" { return "grok-4.5" }
      return model
    default:
      switch normalized {
      case "gpt-5.3-codex", "gpt-5-3-codex":
        return "gpt-5.5"
      case "gpt-5.5", "gpt-5.5-pro", "gpt-5.4", "gpt-5.2", "gpt-5":
        return normalized
      default:
        return model
      }
    }
  }

  private static func normalizedAdvisor(provider: String, advisor: String?) -> String? {
    guard provider.lowercased() == "claude", let advisor = normalizedString(advisor) else { return nil }
    let normalized = advisor.lowercased().replacingOccurrences(of: "_", with: "-")
    if ["off", "none", "no", "false", "0", "disable", "disabled"].contains(normalized) { return nil }
    if normalized.contains("fable") { return "fable" }
    if normalized.contains("opus") { return "opus" }
    if normalized.contains("sonnet") { return "sonnet" }
    return advisor
  }

  // MARK: - Default view preference (per provider)
  //
  // Claude/Codex only: whether tapping the DM opens the classic chat (bubbles +
  // wallpaper) or goes straight to the full-page agent runtime view. Defaults to .chat.

  private static func defaultViewKey(_ provider: String) -> String {
    "agentBridge.defaultView.\(provider.lowercased())"
  }

  static func defaultView(provider: String) -> AgentBridgeDefaultView {
    guard !provider.isEmpty else { return .chat }
    let raw = UserDefaults.standard.string(forKey: defaultViewKey(provider)) ?? AgentBridgeDefaultView.chat.rawValue
    return AgentBridgeDefaultView(rawValue: raw) ?? .chat
  }

  static func setDefaultView(provider: String, _ view: AgentBridgeDefaultView) {
    UserDefaults.standard.set(view.rawValue, forKey: defaultViewKey(provider))
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  // MARK: - Resume target (per provider)
  //
  // Default behavior is "new task per message": each outgoing agent message starts a
  // fresh session on the bridge. When the user explicitly picks "continue a session"
  // in the input bar, we stash the chosen session id (provider-appropriate: Claude
  // session_id / Codex thread_id) here; `agentBridgeMetadataForOutgoing` then attaches
  // it as `agentBridgeResumeSessionId`. The selection is sticky (surfaced in the
  // control title) until the user clears it or picks a different one.

  private static func resumeKey(_ provider: String) -> String {
    "agentBridge.resume.\(provider.lowercased())"
  }

  static func selectedResumeSession(provider: String) -> (id: String, topic: String)? {
    guard
      let data = UserDefaults.standard.data(forKey: resumeKey(provider)),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = normalizedString(object["id"])
    else {
      return nil
    }
    return (id: id, topic: normalizedString(object["topic"]) ?? "Session")
  }

  static func setResumeSession(provider: String, id: String, topic: String) {
    let object: [String: Any] = ["id": id, "topic": topic]
    if let data = try? JSONSerialization.data(withJSONObject: object) {
      UserDefaults.standard.set(data, forKey: resumeKey(provider))
      NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
  }

  static func clearResumeSession(provider: String) {
    UserDefaults.standard.removeObject(forKey: resumeKey(provider))
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  @discardableResult
  static func ensureValidSelection(from repositories: [AgentBridgeRepository]) -> AgentBridgeRepository? {
    // Keep the stored choice only while it still exists on the connected computer.
    // Never auto-pick a repo the user didn't choose — this previously defaulted to
    // the first repo, which silently routed every task to e.g. "vibe".
    guard let selected = selectedRepository() else { return nil }
    if repositories.isEmpty { return selected }
    return repositories.contains(where: { $0.id == selected.id || $0.cwd == selected.cwd })
      ? selected : nil
  }

  private static func boolValue(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
      return ["true", "1", "yes"].contains(value.lowercased())
    }
    return false
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }
}

/// A freshly minted, single-use pairing code plus the exact command the user runs
/// on their computer. The QR encodes the same command so it can be scanned and
/// pasted into a terminal.
struct AgentPairingTicket {
  let code: String
  let expiresIn: Int
  /// Root server URL (no trailing `/api`) the daemon dials out to.
  let serverBase: String

  /// The one-liner the user runs on their computer to pair + go online.
  var command: String {
    "npx @vibegram/agent-bridge --code \(code) --server \(serverBase)"
  }

  /// Payload encoded into the QR. We embed the full command so a desktop QR
  /// reader yields something directly runnable.
  var qrPayload: String { command }
}

enum AgentPairingError: LocalizedError {
  case noSession
  case invalidURL
  case invalidResponse
  case http(Int, String)
  case decode

  var errorDescription: String? {
    switch self {
    case .noSession:
      return "The current session is unavailable."
    case .invalidURL:
      return "The stored API configuration is invalid."
    case .invalidResponse:
      return "The server did not return a valid response."
    case let .http(status, body):
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      return "Request failed with status \(status)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
    case .decode:
      return "The pairing response could not be parsed."
    }
  }
}

/// REST client for the agent-bridge pairing endpoints. Mirrors the HTTP shape used
/// by `ChatHomeService` / `ContactSearchService` (Bearer auth, ngrok skip header).
enum AgentPairingService {
  /// Last successfully fetched bridge status, warmed by EVERY `status()` caller
  /// (connect panel, profile card, history view). Callers read it to decide
  /// synchronously whether a computer is already online — so the connect gate never
  /// flashes its panel on a chat that's actually connected. There is one computer per
  /// account, so a single global snapshot is correct.
  @MainActor private(set) static var lastStatus: AgentBridgeStatus?

  /// Plain (non-actor) mirror of the connected computer's name + online flag, so UIKit
  /// surfaces (the agent runtime header) can read it synchronously without hopping to
  /// the main actor. Single writer (`status()`), display-only readers.
  nonisolated(unsafe) static var lastDeviceLabel: String?
  nonisolated(unsafe) static var lastConnected: Bool = false
  /// Full non-actor snapshot of the last status (repos / running tasks / paired), so
  /// UIKit surfaces (the chat's repo chip + History) can read it synchronously.
  nonisolated(unsafe) static var lastStatusSnapshot: AgentBridgeStatus?

  /// Wall-clock time of the last successful `status()` fetch. Lets the connect gate tell
  /// a JUST-warmed snapshot (trustworthy → skip the redundant re-verify that causes the
  /// input↔panel flip) from a stale one.
  nonisolated(unsafe) static var lastStatusFetchedAt: Date?

  /// True when the cached status was fetched within `maxAge` seconds — i.e. fresh enough
  /// to drive the gate without another network round-trip.
  static func statusIsFresh(maxAge: TimeInterval = 8) -> Bool {
    guard let at = lastStatusFetchedAt else { return false }
    return Date().timeIntervalSince(at) < maxAge
  }

  /// GET /api/agent-bridge/status
  static func status(config: AppSessionConfig) async throws -> AgentBridgeStatus {
    let request = try buildRequest(config: config, path: "/agent-bridge/status", method: "GET")
    let object = try await perform(request)
    let repositories = repositoryList(object["repositories"])
    let devices = deviceList(object["devices"])
    let runningTasks = runningTaskList(object["runningTasks"] ?? object["running_tasks"])
    let result = AgentBridgeStatus(
      connected: boolValue(object["connected"]),
      paired: boolValue(object["paired"]),
      repositories: repositories.isEmpty ? devices.flatMap(\.repositories) : repositories,
      devices: devices,
      runningTasks: runningTasks.isEmpty ? devices.flatMap(\.runningTasks) : runningTasks
    )
    lastDeviceLabel = result.devices.first?.label
    lastConnected = result.connected
    lastStatusSnapshot = result
    lastStatusFetchedAt = Date()

    await MainActor.run { lastStatus = result }
    return result
  }

  /// Timestamp of the last successful (or attempted) warm-up, so `warmStatusIfStale`
  /// coalesces the many surfaces that want fresh status (home appear, foreground) into
  /// at most one request per `maxAge` window.
  @MainActor private static var lastWarmAttemptAt: Date?

  /// Proactively fetch bridge status in the background so the connect gate can decide
  /// SYNCHRONOUSLY (via `lastConnected` / `lastStatusSnapshot`) the instant an agent DM
  /// opens — no per-open network round-trip, no hidden-composer wait, no input↔panel
  /// flicker. Safe to call liberally (home appear, foreground): it throttles itself and
  /// never throws. Skips entirely when there is nothing paired to poll for is handled
  /// server-side (the endpoint returns quickly).
  @MainActor
  static func warmStatusIfStale(config: AppSessionConfig, maxAge: TimeInterval = 8) {
    if let last = lastWarmAttemptAt, Date().timeIntervalSince(last) < maxAge { return }
    lastWarmAttemptAt = Date()
    Task { _ = try? await status(config: config) }
  }

  /// POST /api/agent-bridge/pairing
  static func requestPairing(config: AppSessionConfig) async throws -> AgentPairingTicket {
    let request = try buildRequest(config: config, path: "/agent-bridge/pairing", method: "POST")
    let object = try await perform(request)
    guard let code = normalizedString(object["pairing_code"] ?? object["pairingCode"]) else {
      throw AgentPairingError.decode
    }
    let expiresIn = intValue(object["expires_in"] ?? object["expiresIn"]) ?? 600
    return AgentPairingTicket(
      code: code,
      expiresIn: expiresIn,
      serverBase: serverBase(config: config)
    )
  }

  /// DELETE /api/agent-bridge
  static func revoke(config: AppSessionConfig) async throws {
    let request = try buildRequest(config: config, path: "/agent-bridge", method: "DELETE")
    _ = try await perform(request)
  }

  /// POST /api/agent-bridge/authorize — authorize a scanned desktop pairing
  /// request, binding the paired computer to this account.
  static func authorize(config: AppSessionConfig, requestId: String) async throws {
    let request = try buildRequest(
      config: config, path: "/agent-bridge/authorize", method: "POST",
      body: ["request_id": requestId])
    _ = try await perform(request)
  }

  /// Extract the `request_id` from a scanned QR payload (`vibegram-pair:<id>`).
  /// Returns nil for anything that isn't one of our pairing codes.
  static func requestId(fromScanned payload: String) -> String? {
    let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "vibegram-pair:"
    guard trimmed.hasPrefix(prefix) else { return nil }
    var body = String(trimmed.dropFirst(prefix.count))
    // The pairing QR may carry the E2E runtime key in a `#<b64>` fragment. Capture
    // it (server-blind) and keep only the request id.
    if let hash = body.firstIndex(of: "#") {
      let key = String(body[body.index(after: hash)...])
      if !key.isEmpty { AgentRuntimeCrypto.storeKey(key) }
      body = String(body[..<hash])
    }
    return body.isEmpty ? nil : body
  }

  // MARK: - URL building

  /// Root server URL without a trailing `/api`. The daemon appends `/api/...` and
  /// the websocket path itself, so it expects the bare origin.
  static func serverBase(config: AppSessionConfig) -> String {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    if base.lowercased().hasSuffix("/api") {
      base = String(base.dropLast(4))
      while base.hasSuffix("/") { base.removeLast() }
    }
    return base
  }

  private static func apiBase(config: AppSessionConfig) -> String {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    return base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
  }

  private static func buildRequest(
    config: AppSessionConfig,
    path: String,
    method: String,
    body: [String: Any]? = nil
  ) throws -> URLRequest {
    guard let url = URL(string: apiBase(config: config) + path) else {
      throw AgentPairingError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 16
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    if let body {
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }
    return request
  }

  private static func perform(_ request: URLRequest) async throws -> [String: Any] {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AgentPairingError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw AgentPairingError.http(httpResponse.statusCode, body)
    }
    if data.isEmpty { return [:] }
    let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return (object as? [String: Any]) ?? [:]
  }

  // MARK: - Parsing helpers

  private static func boolValue(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
      return ["true", "1", "yes"].contains(value.lowercased())
    }
    return false
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }

  private static func repositoryList(_ value: Any?) -> [AgentBridgeRepository] {
    guard let values = value as? [[String: Any]] else { return [] }
    return values.compactMap(repository)
  }

  private static func repository(_ object: [String: Any]) -> AgentBridgeRepository? {
    guard let path = normalizedString(object["path"] ?? object["cwd"]) else { return nil }
    let cwd = normalizedString(object["cwd"]) ?? path
    let id = normalizedString(object["id"]) ?? path
    return AgentBridgeRepository(
      id: id,
      name: normalizedString(object["name"]) ?? URL(fileURLWithPath: path).lastPathComponent,
      path: path,
      cwd: cwd,
      source: normalizedString(object["source"]),
      isGitRepository: boolValue(object["git"])
    )
  }

  private static func deviceList(_ value: Any?) -> [AgentBridgeDevice] {
    guard let values = value as? [[String: Any]] else { return [] }
    return values.map { object in
      AgentBridgeDevice(
        label: normalizedString(object["deviceLabel"] ?? object["device_label"]) ?? "Computer",
        cwd: normalizedString(object["cwd"]),
        repositories: repositoryList(object["repositories"]),
        runningTasks: runningTaskList(object["runningTasks"] ?? object["running_tasks"])
      )
    }
  }

  private static func runningTaskList(_ value: Any?) -> [AgentBridgeRunningTask] {
    guard let values = value as? [[String: Any]] else { return [] }
    return values.compactMap(runningTask)
  }

  private static func runningTask(_ object: [String: Any]) -> AgentBridgeRunningTask? {
    guard
      let taskId = normalizedString(object["taskId"] ?? object["task_id"])
        ?? normalizedString(object["id"])
    else {
      return nil
    }
    return AgentBridgeRunningTask(
      provider: normalizedString(object["provider"]) ?? "",
      chatId: normalizedString(object["chatId"] ?? object["chat_id"]) ?? "",
      taskId: taskId,
      sessionId: normalizedString(object["sessionId"] ?? object["session_id"]),
      topic: normalizedString(object["topic"]) ?? "Running task",
      repoId: normalizedString(object["repoId"] ?? object["repo_id"]),
      repoName: normalizedString(object["repoName"] ?? object["repo_name"]),
      project: normalizedString(object["project"] ?? object["cwd"]),
      projectName: normalizedString(object["projectName"] ?? object["project_name"]),
      cwd: normalizedString(object["cwd"]),
      workMode: normalizedString(object["workMode"] ?? object["work_mode"]),
      model: normalizedString(object["model"]),
      startedAt: normalizedString(object["startedAt"] ?? object["started_at"])
    )
  }
}

// MARK: - Direct-LAN transport (phone side)

/// The user-visible transport preference (see the connection sheet's Auto/Local/Cloud
/// control). Auto prefers the local Wi-Fi link when the Mac is reachable and falls back to
/// the cloud relay when it isn't; Local pins the direct link; Cloud pins the relay.
enum AgentBridgeTransportPreference: String, CaseIterable {
  case auto
  case local
  case cloud
}

enum AgentBridgeTransport {
  private static let key = "agentBridge.transportPreference"
  static var preference: AgentBridgeTransportPreference {
    get { AgentBridgeTransportPreference(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
  }
}

/// Discovers the paired Mac's bridge on the local network (Bonjour `_vibegram-bridge._tcp`)
/// and opens a direct, authenticated WebSocket to it — the fast path that bypasses the
/// cloud relay when phone and Mac share a Wi-Fi. This NEVER replaces the cloud connection
/// (remote access needs it); it's an additive accelerator. Auth is the same arte1
/// challenge-response the bridge enforces: the bridge sends a nonce, we return it sealed
/// with the shared pairing key (AgentRuntimeCrypto), proving we're the paired phone before
/// any traffic flows. Phase 3a here = discovery + authenticated link + observable state;
/// routing real history/stream traffic over it is the next phase.
@available(iOS 13.0, *)
final class LanBridgeService {
  static let shared = LanBridgeService()

  enum State: Equatable {
    case unavailable        // no pairing key on this device → LAN link impossible
    case idle               // not searching (e.g. Cloud pinned)
    case searching          // browsing Bonjour, Mac not seen yet
    case found(String)      // service discovered, not yet authenticated
    case connecting
    case authenticated(String)
    case failed(String)
  }

  static let stateChangedNotification = Notification.Name("LanBridgeStateChanged")

  private let queue = DispatchQueue(label: "vibe.lan.bridge")
  private var browser: NWBrowser?
  private var connection: NWConnection?
  private var handshakeNonce: String?
  private var connectedName: String?
  private var authed = false
  private var desiredUserId: String?
  private var _state: State = .idle

  /// Last known state — safe to read from the main thread for a UI hint.
  var currentState: State { queue.sync { _state } }

  private init() {}

  var isAuthenticated: Bool {
    if case .authenticated = currentState { return true }
    return false
  }

  /// Begin (or resume) discovery. Respects the saved preference: Cloud → stays idle.
  func start(userId: String?) {
    queue.async {
      self.desiredUserId = userId
      guard AgentRuntimeCrypto.hasKey else {
        self.setStateLocked(.unavailable)
        NSLog("[LanBridge] no pairing key — direct LAN link unavailable (cloud relay only)")
        return
      }
      guard AgentBridgeTransport.preference != .cloud else {
        self.setStateLocked(.idle)
        return
      }
      guard self.browser == nil else { return } // already searching / connected
      self.startBrowseLocked()
    }
  }

  func stop() {
    queue.async { self.teardownAllLocked(state: .idle) }
  }

  /// React to the user flipping the Auto/Local/Cloud control.
  func applyPreference(_ pref: AgentBridgeTransportPreference) {
    queue.async {
      guard AgentRuntimeCrypto.hasKey else { self.setStateLocked(.unavailable); return }
      if pref == .cloud {
        self.teardownAllLocked(state: .idle)
      } else if self.browser == nil {
        self.startBrowseLocked()
      }
    }
  }

  // MARK: Discovery

  private func startBrowseLocked() {
    let params = NWParameters()
    params.includePeerToPeer = true
    let browser = NWBrowser(
      for: .bonjour(type: "_vibegram-bridge._tcp", domain: nil), using: params)
    browser.stateUpdateHandler = { [weak self] st in
      guard let self else { return }
      self.queue.async {
        switch st {
        case .ready:
          NSLog("[LanBridge] browsing _vibegram-bridge._tcp on the local network")
        case .failed(let error):
          NSLog("[LanBridge] browse failed: \(error)")
          self.setStateLocked(.failed("browse: \(error)"))
        case .cancelled:
          break
        default:
          break
        }
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      guard let self else { return }
      self.queue.async { self.handleBrowseResultsLocked(results) }
    }
    self.browser = browser
    setStateLocked(.searching)
    browser.start(queue: queue)
  }

  private func handleBrowseResultsLocked(_ results: Set<NWBrowser.Result>) {
    guard !authed, connection == nil else { return }
    guard let pick = pickResultLocked(results) else {
      if results.isEmpty { setStateLocked(.searching) }
      return
    }
    var name = "your Mac"
    if case let .service(svcName, _, _, _) = pick.endpoint { name = svcName }
    connectedName = name
    setStateLocked(.found(name))
    NSLog("[LanBridge] discovered bridge \"\(name)\" — connecting")
    connectLocked(to: pick.endpoint, name: name)
  }

  /// Prefer the bridge advertising OUR account's uid (TXT record); fall back to the first.
  private func pickResultLocked(_ results: Set<NWBrowser.Result>) -> NWBrowser.Result? {
    let all = Array(results)
    if let uid = desiredUserId, !uid.isEmpty {
      let match = all.first { result in
        if case let .bonjour(txt) = result.metadata { return txt["uid"] == uid }
        return false
      }
      if let match { return match }
    }
    return all.first
  }

  // MARK: Connection + handshake

  private func connectLocked(to endpoint: NWEndpoint, name: String) {
    let ws = NWProtocolWebSocket.Options()
    ws.autoReplyPing = true
    let params = NWParameters.tcp
    params.includePeerToPeer = true
    params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
    let conn = NWConnection(to: endpoint, using: params)
    connection = conn
    setStateLocked(.connecting)
    conn.stateUpdateHandler = { [weak self] st in
      guard let self else { return }
      self.queue.async {
        switch st {
        case .ready:
          NSLog("[LanBridge] socket ready to \(name) — starting handshake")
          self.receiveLocked()
        case .failed(let error):
          self.teardownConnectionLocked(reason: "connect: \(error)")
        case .cancelled:
          break
        default:
          break
        }
      }
    }
    conn.start(queue: queue)
  }

  private func receiveLocked() {
    connection?.receiveMessage { [weak self] data, _, _, error in
      guard let self else { return }
      self.queue.async {
        if let error {
          self.teardownConnectionLocked(reason: "recv: \(error)")
          return
        }
        if let data, !data.isEmpty { self.handleFrameLocked(data) }
        if self.connection != nil { self.receiveLocked() }
      }
    }
  }

  private func handleFrameLocked(_ data: Data) {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = obj["type"] as? String
    else { return }

    if !authed {
      switch type {
      case "lan_challenge":
        guard let nonce = obj["nonce"] as? String else { return }
        handshakeNonce = nonce
        guard let proof = AgentRuntimeCrypto.encrypt(["nonce": nonce, "role": "phone"]) else {
          teardownConnectionLocked(reason: "no key to seal proof")
          return
        }
        sendLocked(["type": "lan_auth", "proof": proof])
      case "lan_ready":
        let opened = AgentRuntimeCrypto.decrypt(obj["proof"])
        if let opened, opened["role"] as? String == "bridge",
          (opened["nonce"] as? String) == handshakeNonce
        {
          authed = true
          let name = connectedName ?? "your Mac"
          setStateLocked(.authenticated(name))
          NSLog("[LanBridge] authenticated with \(name) ✓ — direct LAN link ready")
        } else {
          teardownConnectionLocked(reason: "bridge proof invalid — not the paired Mac")
        }
      default:
        break
      }
      return
    }

    // Authenticated. Phase 3b routes history_result / progress / result frames into the
    // ChatEngine ingest here; for now, prove the link stays live.
    NSLog("[LanBridge] frame over LAN: type=\(type)")
  }

  private func sendLocked(_ obj: [String: Any]) {
    guard let conn = connection,
      let data = try? JSONSerialization.data(withJSONObject: obj)
    else { return }
    let meta = NWProtocolWebSocket.Metadata(opcode: .text)
    let ctx = NWConnection.ContentContext(identifier: "lan-send", metadata: [meta])
    conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
  }

  // MARK: Teardown

  private func teardownConnectionLocked(reason: String) {
    NSLog("[LanBridge] link down: \(reason)")
    connection?.cancel()
    connection = nil
    authed = false
    handshakeNonce = nil
    // Keep browsing so the link re-establishes when the Mac reappears.
    if browser != nil {
      setStateLocked(.searching)
    } else {
      setStateLocked(.failed(reason))
    }
  }

  private func teardownAllLocked(state: State) {
    browser?.cancel()
    browser = nil
    connection?.cancel()
    connection = nil
    authed = false
    handshakeNonce = nil
    connectedName = nil
    setStateLocked(state)
  }

  private func setStateLocked(_ next: State) {
    guard _state != next else { return }
    _state = next
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: Self.stateChangedNotification, object: nil)
    }
  }
}
