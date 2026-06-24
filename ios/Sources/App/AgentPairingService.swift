import Foundation

/// Whether a paired computer (the `vibe-bridge` daemon) is connected right now.
struct AgentBridgeStatus {
  /// A daemon is currently online (Presence on `bridge:<user_id>`).
  let connected: Bool
  /// The account has at least one non-revoked bridge token on record.
  let paired: Bool

  static let disconnected = AgentBridgeStatus(connected: false, paired: false)
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
    "npx vibe-bridge --code \(code) --server \(serverBase)"
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
    return AgentBridgeStatus(
      connected: boolValue(object["connected"]),
      paired: boolValue(object["paired"])
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
    method: String
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
}
