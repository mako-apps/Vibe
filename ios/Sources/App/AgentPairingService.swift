import Foundation

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

  static let disconnected = AgentBridgeStatus(
    connected: false,
    paired: false,
    repositories: [],
    devices: []
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
    return AgentBridgeStatus(
      connected: boolValue(object["connected"]),
      paired: boolValue(object["paired"]),
      repositories: repositories.isEmpty ? devices.flatMap(\.repositories) : repositories,
      devices: devices
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
    let id = String(trimmed.dropFirst(prefix.count))
    return id.isEmpty ? nil : id
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
        repositories: repositoryList(object["repositories"])
      )
    }
  }
}
