import CryptoKit
import Foundation

/// End-to-end decryption for the agent runtime payload (file diffs / patches).
///
/// The bridge encrypts the runtime blob with a 32-byte key shared only with this
/// phone — handed over during pairing through the QR, which the Vibe server never
/// sees. We keep that key in the Keychain and decrypt locally so the
/// "files changed" card can render. The server only ever holds opaque ciphertext.
enum AgentRuntimeCrypto {
  /// Keychain account for the shared runtime key (base64 of 32 bytes).
  static let keychainAccount = "agentBridge.runtimeKey"
  private static let blobPrefix = "arte1"

  // The key is read on a hot path (every agent row with an encrypted blob), so
  // cache it in memory and only fall back to the Keychain on a cold miss.
  private static let cacheQueue = DispatchQueue(label: "agentRuntimeCrypto.key")
  private static var cachedKey: Data?
  private static var cacheLoaded = false

  private static func keyData() -> Data? {
    cacheQueue.sync {
      if !cacheLoaded {
        cacheLoaded = true
        if let b64 = SecureKeyStore.shared.retrieveSecret(key: keychainAccount),
          let data = Data(base64Encoded: b64), data.count == 32
        {
          cachedKey = data
        }
      }
      return cachedKey
    }
  }

  /// Persist a runtime key (base64, 32 bytes) handed over by the bridge.
  @discardableResult
  static func storeKey(_ base64Key: String) -> Bool {
    let trimmed = base64Key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: trimmed), data.count == 32 else { return false }
    let ok = SecureKeyStore.shared.storeSecret(key: keychainAccount, value: trimmed)
    if ok { cacheQueue.sync { cachedKey = data; cacheLoaded = true } }
    return ok
  }

  static var hasKey: Bool { keyData() != nil }

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
  /// Live per-action approval routed to your phone. Until the live approval
  /// channel ships, the daemon treats this as safe-propose (same as `.readOnly`).
  case ask = "ask"
  /// Analyse & propose only — never changes files.
  case readOnly = "read_only"
  /// Auto-approve edits + sandboxed command execution.
  case allowEdits = "allow_edits"
  /// No sandbox — the agent can run anything in the selected repo.
  case fullAccess = "full_access"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .ask: return "Ask"
    case .readOnly: return "Read"
    case .allowEdits: return "Auto"
    case .fullAccess: return "Full"
    }
  }

  var subtitle: String {
    switch self {
    case .ask: return "Approve each change or command from your phone"
    case .readOnly: return "Read & propose only — never changes files"
    case .allowEdits: return "Auto-approve edits & sandboxed commands"
    case .fullAccess: return "No sandbox — can run anything (use with care)"
    }
  }

  var icon: String {
    switch self {
    case .ask: return "hand.raised"
    case .readOnly: return "eye"
    case .allowEdits: return "pencil"
    case .fullAccess: return "bolt"
    }
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

enum AgentBridgeSelectionStore {
  static let didChangeNotification = Notification.Name("AgentBridgeSelectionStoreDidChange")

  private static let repositoryKey = "agentBridge.selectedRepository"
  private static let workModeKey = "agentBridge.workMode"

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
    let raw = UserDefaults.standard.string(forKey: workModeKey) ?? AgentBridgeWorkMode.readOnly.rawValue
    return AgentBridgeWorkMode(rawValue: raw) ?? .readOnly
  }

  static func setWorkMode(_ mode: AgentBridgeWorkMode) {
    UserDefaults.standard.set(mode.rawValue, forKey: workModeKey)
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
  /// GET /api/agent-bridge/status
  static func status(config: AppSessionConfig) async throws -> AgentBridgeStatus {
    let request = try buildRequest(config: config, path: "/agent-bridge/status", method: "GET")
    let object = try await perform(request)
    let repositories = repositoryList(object["repositories"])
    let devices = deviceList(object["devices"])
    let runningTasks = runningTaskList(object["runningTasks"] ?? object["running_tasks"])
    return AgentBridgeStatus(
      connected: boolValue(object["connected"]),
      paired: boolValue(object["paired"]),
      repositories: repositories.isEmpty ? devices.flatMap(\.repositories) : repositories,
      devices: devices,
      runningTasks: runningTasks.isEmpty ? devices.flatMap(\.runningTasks) : runningTasks
    )
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
