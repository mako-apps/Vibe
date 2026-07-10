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
  var computerId: String? = nil
  var computerLabel: String? = nil

  var selectionIdentity: String {
    "\(computerId ?? "legacy"):\(id)"
  }
}

struct AgentBridgeDevice: Hashable {
  let label: String
  let cwd: String?
  let repositories: [AgentBridgeRepository]
  let runningTasks: [AgentBridgeRunningTask]
  var id: String = ""
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
  case max

  var id: String { rawValue }

  var title: String {
    switch self {
    case .low: return "Low"
    case .medium: return "Medium"
    case .high: return "High"
    case .extraHigh: return "Extra High"
    case .max: return "Max"
    }
  }

  /// Provider-native effort token (Claude / Codex / Grok spawn args).
  var providerEffort: String {
    switch self {
    case .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    case .extraHigh: return "xhigh"
    case .max: return "max"
    }
  }

  var claudeEffort: String { providerEffort }

  var codexEffort: String {
    // Codex historically lacked max; map max → xhigh when unsupported.
    switch self {
    case .low: return "low"
    case .medium: return "medium"
    case .high: return "high"
    case .extraHigh, .max: return "xhigh"
    }
  }

  static func fromProviderEffort(_ raw: String?) -> AgentBridgeIntelligenceLevel? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !raw.isEmpty
    else { return nil }
    switch raw.replacingOccurrences(of: "_", with: "-") {
    case "low", "minimal", "none": return .low
    case "medium", "med", "standard": return .medium
    case "high": return .high
    case "xhigh", "extra-high", "extrahigh", "extra_high": return .extraHigh
    case "max", "maximum", "ultrathink": return .max
    default: return nil
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
    let key = provider.lowercased()
    // Prefer live ladder for the selected model when the bridge advertised it.
    let live = AgentBridgeSelectionStore.effortChoices(provider: key)
    let ladder: [String]
    if !live.isEmpty {
      ladder = live
    } else if key == "claude" {
      ladder = ["low", "medium", "high", "xhigh", "max"]
    } else if key == "codex" || key == "gpt" {
      ladder = ["low", "medium", "high", "xhigh"]
    } else if key == "agy" || key == "antigravity" {
      // Effort is part of the agy model name; spawn does not take a separate flag.
      return intelligence.providerEffort
    } else {
      ladder = ["low", "medium", "high"]
    }
    let base: String
    if key == "claude" {
      base = intelligence.claudeEffort
    } else if key == "codex" || key == "gpt" {
      base = intelligence.codexEffort
    } else {
      base = intelligence.providerEffort
    }
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

/// One selectable model from the paired bridge (live provider catalog).
struct AgentBridgeModelChoice: Hashable, Identifiable {
  var id: String { value }
  let title: String
  let subtitle: String?
  /// Exact provider id stored/sent as agentBridgeModel (never invent aliases).
  let value: String
  let isDefault: Bool
  /// Provider-native effort/thinking levels for this model (e.g. low…max).
  let efforts: [String]
  let defaultEffort: String?
  /// `live` | `cache` | `seed` — display/debug only.
  let source: String?
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
  /// Live model catalogs keyed by provider (`claude`, `codex`, `grok`, `agy`).
  let models: [String: [AgentBridgeModelChoice]]

  static let disconnected = AgentBridgeStatus(
    connected: false,
    paired: false,
    repositories: [],
    devices: [],
    runningTasks: [],
    models: [:]
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

  private static let globalRepositoryKey = "agentBridge.selectedRepository"
  private static let workModeKey = "agentBridge.workMode"
  private static let intelligenceKey = "agentBridge.intelligence"
  private static let speedKey = "agentBridge.speed"
  private static func modelKey(_ provider: String) -> String {
    "agentBridge.model.\(provider.lowercased())"
  }
  private static func advisorKey(_ provider: String) -> String {
    "agentBridge.advisor.\(provider.lowercased())"
  }
  /// Per-chat repo selection so each group can keep its own working directory
  /// without clobbering a Claude/Codex DM pick (and vice versa).
  private static func repositoryStorageKey(chatId: String?) -> String {
    let trimmed = chatId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return globalRepositoryKey }
    return "\(globalRepositoryKey).chat.\(trimmed)"
  }

  /// Resolve the selected repository. When `chatId` is set, prefers that chat's
  /// stored pick and falls back to the global selection so older installs keep working.
  static func selectedRepository(chatId: String? = nil) -> AgentBridgeRepository? {
    if let chatId, !chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let scoped = decodeRepository(forKey: repositoryStorageKey(chatId: chatId))
    {
      return scoped
    }
    return decodeRepository(forKey: globalRepositoryKey)
  }

  static func select(_ repository: AgentBridgeRepository, chatId: String? = nil) {
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
    if let computerId = repository.computerId {
      object["computerId"] = computerId
    }
    if let computerLabel = repository.computerLabel {
      object["computerLabel"] = computerLabel
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    // Always keep the global key in sync so legacy callers without chatId still work.
    UserDefaults.standard.set(data, forKey: globalRepositoryKey)
    if let chatId, !chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      UserDefaults.standard.set(data, forKey: repositoryStorageKey(chatId: chatId))
    }
    NotificationCenter.default.post(
      name: didChangeNotification,
      object: nil,
      userInfo: chatId.map { ["chatId": $0] }
    )
  }

  private static func decodeRepository(forKey key: String) -> AgentBridgeRepository? {
    guard
      let data = UserDefaults.standard.data(forKey: key),
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
      isGitRepository: boolValue(object["git"]),
      computerId: normalizedString(object["computerId"] ?? object["computer_id"]),
      computerLabel: normalizedString(object["computerLabel"] ?? object["computer_label"])
    )
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

  /// Live catalogs from the last bridge status (provider CLI/API). Empty until status lands.
  nonisolated(unsafe) private static var liveModelsByProvider: [String: [AgentBridgeModelChoice]] = [:]
  private static let liveModelsCacheKey = "agentBridge.liveModelsByProvider.v1"

  /// Selectable models per provider. Prefers live catalog from the paired bridge
  /// (refreshed on status); falls back to a built-in seed so the picker never empties.
  static func modelChoices(provider: String) -> [(title: String, subtitle: String?, value: String)] {
    hydrateLiveModelsFromDisk()
    let key = provider.lowercased()
    let liveKey = key == "antigravity" ? "agy" : key
    if let live = liveModelsByProvider[liveKey], !live.isEmpty {
      return live.map { ($0.title, $0.subtitle, $0.value) }
    }
    return hardcodedModelChoices(provider: key)
  }

  static func liveModelChoices(provider: String) -> [AgentBridgeModelChoice] {
    hydrateLiveModelsFromDisk()
    let key = provider.lowercased()
    let liveKey = key == "antigravity" ? "agy" : key
    return liveModelsByProvider[liveKey] ?? []
  }

  /// Provider-native effort/thinking levels for the selected (or default) model.
  /// Empty for Agy (effort is part of the model label).
  static func effortChoices(provider: String, model: String? = nil) -> [String] {
    hydrateLiveModelsFromDisk()
    let key = provider.lowercased()
    let liveKey = key == "antigravity" ? "agy" : key
    if liveKey == "agy" { return [] }
    let rows = liveModelsByProvider[liveKey] ?? []
    let wanted = model.flatMap { normalizedString($0) }
    if let wanted,
      let match = rows.first(where: {
        $0.value.caseInsensitiveCompare(wanted) == .orderedSame
      }),
      !match.efforts.isEmpty
    {
      return match.efforts
    }
    if let selected = selectedModel(provider: provider),
      let match = rows.first(where: { $0.value.caseInsensitiveCompare(selected) == .orderedSame }),
      !match.efforts.isEmpty
    {
      return match.efforts
    }
    var seen = Set<String>()
    var ordered: [String] = []
    for row in rows {
      for effort in row.efforts where seen.insert(effort).inserted {
        ordered.append(effort)
      }
    }
    if !ordered.isEmpty { return ordered }
    switch liveKey {
    case "claude": return ["low", "medium", "high", "xhigh", "max"]
    case "codex", "gpt": return ["low", "medium", "high", "xhigh"]
    case "grok": return ["low", "medium", "high"]
    default: return ["low", "medium", "high"]
    }
  }

  /// Thinking picker rows derived from live provider effort ladders.
  static func intelligenceChoices(provider: String, model: String? = nil) -> [AgentBridgeIntelligenceLevel] {
    let efforts = effortChoices(provider: provider, model: model)
    let mapped = efforts.compactMap { AgentBridgeIntelligenceLevel.fromProviderEffort($0) }
    if !mapped.isEmpty { return mapped }
    return Array(AgentBridgeIntelligenceLevel.allCases)
  }

  /// Force-refresh model catalogs from the bridge (call when opening the model picker).
  @MainActor
  static func refreshModelsIfPossible(config: AppSessionConfig? = nil) {
    hydrateLiveModelsFromDisk()
    guard let config = config ?? AppSessionConfig.current else { return }
    AgentPairingService.warmStatusIfStale(config: config, maxAge: 0)
  }

  /// Update in-memory model catalogs from a bridge status payload and persist last-good.
  static func ingestLiveModels(_ models: [String: [AgentBridgeModelChoice]]) {
    guard !models.isEmpty else { return }
    var next = liveModelsByProvider
    for (key, list) in models where !list.isEmpty {
      next[key.lowercased()] = list
    }
    liveModelsByProvider = next
    persistLiveModels(next)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  /// Load last-good live catalogs so cold start does not flash seed until status returns.
  static func hydrateLiveModelsFromDisk() {
    guard liveModelsByProvider.isEmpty else { return }
    guard let data = UserDefaults.standard.data(forKey: liveModelsCacheKey),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }
    let parsed = parseProviderModelsMap(object)
    if !parsed.isEmpty { liveModelsByProvider = parsed }
  }

  private static func persistLiveModels(_ models: [String: [AgentBridgeModelChoice]]) {
    var out: [String: [[String: Any]]] = [:]
    for (key, rows) in models {
      out[key] = rows.map { row in
        var dict: [String: Any] = [
          "id": row.value,
          "title": row.title,
          "isDefault": row.isDefault,
          "efforts": row.efforts,
        ]
        if let subtitle = row.subtitle { dict["subtitle"] = subtitle }
        if let defaultEffort = row.defaultEffort { dict["defaultEffort"] = defaultEffort }
        if let source = row.source { dict["source"] = source }
        return dict
      }
    }
    if let data = try? JSONSerialization.data(withJSONObject: out) {
      UserDefaults.standard.set(data, forKey: liveModelsCacheKey)
    }
  }

  /// Parse `status.models` map: `{ "claude": [ {id,title,...}, … ], … }`.
  static func parseProviderModelsMap(_ value: Any?) -> [String: [AgentBridgeModelChoice]] {
    guard let object = value as? [String: Any] else { return [:] }
    var out: [String: [AgentBridgeModelChoice]] = [:]
    for (rawKey, rawRows) in object {
      let key = rawKey.lowercased()
      let rows: [[String: Any]]
      if let list = rawRows as? [[String: Any]] {
        rows = list
      } else if let wrapped = rawRows as? [String: Any],
        let items = wrapped["items"] as? [[String: Any]]
      {
        rows = items
      } else {
        continue
      }
      let choices = rows.compactMap(parseModelChoice)
      if !choices.isEmpty { out[key] = choices }
    }
    return out
  }

  private static func parseModelChoice(_ object: [String: Any]) -> AgentBridgeModelChoice? {
    guard
      let value = normalizedString(
        object["id"] ?? object["value"] ?? object["apiId"] ?? object["api_id"])
    else { return nil }
    let title =
      normalizedString(
        object["title"] ?? object["name"] ?? object["display_name"] ?? object["displayName"])
      ?? value
    let efforts: [String]
    if let list = object["efforts"] as? [String] {
      efforts = list.compactMap { normalizedString($0) }
    } else if let list = object["efforts"] as? [Any] {
      efforts = list.compactMap { normalizedString($0) }
    } else {
      efforts = []
    }
    return AgentBridgeModelChoice(
      title: title,
      subtitle: normalizedString(object["subtitle"]),
      value: value,
      isDefault: boolValue(object["isDefault"] ?? object["is_default"] ?? object["default"]),
      efforts: efforts,
      defaultEffort: normalizedString(object["defaultEffort"] ?? object["default_effort"]),
      source: normalizedString(object["source"])
    )
  }

  private static func hardcodedModelChoices(provider: String) -> [(title: String, subtitle: String?, value: String)] {
    // LAST RESORT only — live Anthropic / grok / agy / codex catalogs supersede these.
    switch provider.lowercased() {
    case "claude":
      return [
        ("Claude Haiku 4.5", "Seed fallback", "claude-haiku-4-5-20251001"),
        ("Claude Sonnet 5", "Seed fallback", "claude-sonnet-5"),
        ("Claude Opus 4.8", "Seed fallback", "claude-opus-4-8"),
        ("Claude Fable 5", "Seed fallback", "claude-fable-5"),
      ]
    case "grok":
      return [
        ("Grok 4.5", "Seed fallback", "grok-4.5"),
        ("Composer 2.5 Fast", "Seed fallback", "grok-composer-2.5-fast"),
      ]
    case "agy", "antigravity":
      return [
        ("Gemini 3.1 Pro (High)", "Seed fallback", "Gemini 3.1 Pro (High)"),
        ("Gemini 3.1 Pro (Low)", "Seed fallback", "Gemini 3.1 Pro (Low)"),
        ("Gemini 3.5 Flash (High)", "Seed fallback", "Gemini 3.5 Flash (High)"),
        ("Gemini 3.5 Flash (Medium)", "Seed fallback", "Gemini 3.5 Flash (Medium)"),
        ("Gemini 3.5 Flash (Low)", "Seed fallback", "Gemini 3.5 Flash (Low)"),
        ("Claude Sonnet 4.6 (Thinking)", "Seed fallback", "Claude Sonnet 4.6 (Thinking)"),
        ("Claude Opus 4.6 (Thinking)", "Seed fallback", "Claude Opus 4.6 (Thinking)"),
        ("GPT-OSS 120B (Medium)", "Seed fallback", "GPT-OSS 120B (Medium)"),
      ]
    default:
      return [
        ("GPT-5.6 Sol", "Seed fallback", "gpt-5.6-sol"),
        ("GPT-5.6", "Seed fallback", "gpt-5.6"),
        ("GPT-5.5", "Seed fallback", "gpt-5.5"),
        ("GPT-5.5 Pro", "Seed fallback", "gpt-5.5-pro"),
        ("GPT-5.4", "Seed fallback", "gpt-5.4"),
        ("GPT-5.2", "Seed fallback", "gpt-5.2"),
        ("GPT-5", "Seed fallback", "gpt-5"),
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
    // Prefer bridge-marked default from live catalog when present.
    if let liveDefault = liveModelChoices(provider: provider).first(where: { $0.isDefault }) {
      return liveDefault.value
    }
    switch provider.lowercased() {
    case "claude": return "claude-sonnet-5"
    case "grok": return "grok-4.5"
    case "agy", "antigravity": return "Gemini 3.1 Pro (High)"
    case "codex": return "gpt-5.6-sol"
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
    let isAgy = provider.lowercased().contains("agy") || provider.lowercased().contains("antigravity")
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
    // Grok/Agy headless do not parse Claude/Codex slash tasks — keep the palette light.
    let grokTasks: [SlashCommand] = [
      SlashCommand(name: "init", subtitle: "Set up project memory"),
    ]
    let agyTasks: [SlashCommand] = [
      SlashCommand(name: "init", subtitle: "Set up project memory"),
    ]
    let options: [SlashCommand] = [
      SlashCommand(name: "plan", subtitle: "Plan mode: research, don't edit"),
      SlashCommand(
        name: isCodex ? "fast" : "reasoning",
        subtitle: isCodex ? "Faster, lighter responses" : "Adjust thinking depth"),
    ]
    let tasks = isCodex ? codexTasks : (isGrok ? grokTasks : (isAgy ? agyTasks : claudeTasks))
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
    case "agy", "antigravity": return "Agy"
    default: return provider.capitalized
    }
  }

  /// Human title for a model id (or the provider default when nil/unknown). Use this
  /// for the header so the displayed model matches whatever a loaded run reports.
  static func modelTitle(provider: String, model: String?) -> String {
    guard let rawModel = normalizedString(model) else { return defaultModelTitle(provider: provider) }
    // Prefer live display_name; fall back to canonical match then raw id.
    let canonical = normalizedModel(provider: provider, model: rawModel) ?? rawModel
    if let match = modelChoices(provider: provider).first(where: {
      $0.value.caseInsensitiveCompare(canonical) == .orderedSame
        || $0.value.caseInsensitiveCompare(rawModel) == .orderedSame
    }) {
      return match.title
    }
    // Strip common "Claude " prefix noise only for display of raw ids.
    return rawModel
  }

  /// Public canonical-id resolver (e.g. "claude-3-5-sonnet" → "sonnet"). Returns nil
  /// for empty/unset; used to compare a loaded run's model against the menu choices.
  static func canonicalModel(provider: String, model: String?) -> String? {
    normalizedModel(provider: provider, model: normalizedString(model))
  }

  private static func normalizedModel(provider: String, model: String?) -> String? {
    guard let model = normalizedString(model) else { return nil }
    hydrateLiveModelsFromDisk()
    let key = provider.lowercased()
    let liveKey = key == "antigravity" ? "agy" : key
    // Prefer exact match against the live catalog so new models (alpha, fable-5, …)
    // round-trip unchanged without alias collapse.
    if let live = liveModelsByProvider[liveKey] {
      if let exact = live.first(where: { $0.value.caseInsensitiveCompare(model) == .orderedSame }) {
        return exact.value
      }
    }
    let normalized = model.lowercased().replacingOccurrences(of: "_", with: "-")
    switch key {
    case "claude":
      // Exact Anthropic ids pass through (claude-fable-5, claude-sonnet-5, …).
      if normalized.starts(with: "claude-") { return model }
      // Legacy short aliases → current API ids so old UserDefaults keep working.
      if normalized == "fable" || normalized.contains("fable") { return "claude-fable-5" }
      if normalized == "haiku" || normalized.contains("haiku-4-5") {
        return "claude-haiku-4-5-20251001"
      }
      if normalized == "sonnet" || (normalized.contains("sonnet-5") && !normalized.contains("sonnet-4")) {
        return "claude-sonnet-5"
      }
      if normalized == "opus" || normalized.contains("opus-4-8") { return "claude-opus-4-8" }
      if normalized.contains("sonnet") { return "claude-sonnet-5" }
      if normalized.contains("opus") { return "claude-opus-4-8" }
      return model
    case "grok":
      return model
    case "agy", "antigravity":
      // Agy model labels are human-readable and passed through as-is (effort in name).
      return model
    default:
      if normalized == "gpt-5.3-codex" || normalized == "gpt-5-3-codex" { return "gpt-5.5" }
      return model
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
  static func ensureValidSelection(
    from repositories: [AgentBridgeRepository],
    chatId: String? = nil
  ) -> AgentBridgeRepository? {
    // Keep the stored choice only while it still exists on the connected computer.
    // Never auto-pick a repo the user didn't choose — this previously defaulted to
    // the first repo, which silently routed every task to e.g. "vibe".
    guard let selected = selectedRepository(chatId: chatId) else { return nil }
    if repositories.isEmpty { return selected }
    let match = repositories.first(where: {
      let sameRepository = $0.id == selected.id || $0.cwd == selected.cwd
      let sameComputer = selected.computerId == nil || $0.computerId == selected.computerId
      return sameRepository && sameComputer
    })
    if let match, match != selected {
      select(match, chatId: chatId)
    }
    return match
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
    let models = modelCatalogMap(object["models"] ?? object["modelCatalog"] ?? object["model_catalog"])
    let result = AgentBridgeStatus(
      connected: boolValue(object["connected"]),
      paired: boolValue(object["paired"]),
      repositories: repositories.isEmpty ? devices.flatMap(\.repositories) : repositories,
      devices: devices,
      runningTasks: runningTasks.isEmpty ? devices.flatMap(\.runningTasks) : runningTasks,
      models: models
    )
    lastDeviceLabel = result.devices.first?.label
    lastConnected = result.connected
    lastStatusSnapshot = result
    lastStatusFetchedAt = Date()
    if !models.isEmpty {
      AgentBridgeSelectionStore.ingestLiveModels(models)
    }

    await MainActor.run { lastStatus = result }
    return result
  }

  /// Parse `{ "claude": [ { title, value/id, efforts, ... } ], ... }` model catalogs from status.
  private static func modelCatalogMap(_ raw: Any?) -> [String: [AgentBridgeModelChoice]] {
    // Shared parser on the selection store (also used for disk hydrate).
    AgentBridgeSelectionStore.parseProviderModelsMap(raw)
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
      isGitRepository: boolValue(object["git"]),
      computerId: normalizedString(object["computerId"] ?? object["computer_id"]),
      computerLabel: normalizedString(object["computerLabel"] ?? object["computer_label"])
    )
  }

  private static func deviceList(_ value: Any?) -> [AgentBridgeDevice] {
    guard let values = value as? [[String: Any]] else { return [] }
    return values.map { object in
      AgentBridgeDevice(
        label: normalizedString(object["deviceLabel"] ?? object["device_label"]) ?? "Computer",
        cwd: normalizedString(object["cwd"]),
        repositories: repositoryList(object["repositories"]),
        runningTasks: runningTaskList(object["runningTasks"] ?? object["running_tasks"]),
        id: normalizedString(object["computerId"] ?? object["computer_id"] ?? object["id"]) ?? ""
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
