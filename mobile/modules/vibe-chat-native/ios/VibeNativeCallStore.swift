import Foundation

public final class VibeNativeCallStore {
  public static let shared = VibeNativeCallStore()

  private let defaults = UserDefaults.standard
  private let queue = DispatchQueue(label: "vibe.native.call.store")

  private enum Keys {
    static let pendingEvents = "vibe.native.call.pendingEvents"
    static let voipToken = "vibe.native.call.voipToken"
    static let apnsToken = "vibe.native.call.apnsToken"
    static let activeCallsByCallId = "vibe.native.call.activeCallsByCallId"
    static let payloadByUuid = "vibe.native.call.payloadByUuid"
  }

  private init() {}

  public func setVoipToken(_ token: String?) {
    queue.sync {
      defaults.set(token?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.voipToken)
    }
  }

  public func setApnsToken(_ token: String?) {
    queue.sync {
      defaults.set(token?.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.apnsToken)
    }
  }

  public func getPushTokens() -> [String: Any] {
    queue.sync {
      [
        "platform": "ios",
        "voip": defaults.string(forKey: Keys.voipToken),
        "apns": defaults.string(forKey: Keys.apnsToken),
      ]
    }
  }

  public func enqueueEvent(type: String, payload: [String: String]) {
    queue.sync {
      var events = readPendingEventsLocked()
      events.append([
        "type": type,
        "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        "payload": payload,
      ])
      writePendingEventsLocked(events)
    }
  }

  public func drainEvents() -> [[String: Any]] {
    queue.sync {
      let events = readPendingEventsLocked()
      defaults.removeObject(forKey: Keys.pendingEvents)
      return events
    }
  }

  public func setActiveCall(uuid: UUID, payload: [String: String]) {
    queue.sync {
      guard let callId = payload["callId"], !callId.isEmpty else { return }
      var byCallId = defaults.dictionary(forKey: Keys.activeCallsByCallId) as? [String: String] ?? [:]
      var byUuid = defaults.dictionary(forKey: Keys.payloadByUuid) as? [String: [String: String]] ?? [:]
      byCallId[callId] = uuid.uuidString
      byUuid[uuid.uuidString] = payload
      defaults.set(byCallId, forKey: Keys.activeCallsByCallId)
      defaults.set(byUuid, forKey: Keys.payloadByUuid)
    }
  }

  public func payload(for uuid: UUID) -> [String: String]? {
    queue.sync {
      let byUuid = defaults.dictionary(forKey: Keys.payloadByUuid) as? [String: [String: String]]
      return byUuid?[uuid.uuidString]
    }
  }

  public func uuid(forCallId callId: String) -> UUID? {
    queue.sync {
      let byCallId = defaults.dictionary(forKey: Keys.activeCallsByCallId) as? [String: String]
      guard let uuidString = byCallId?[callId] else { return nil }
      return UUID(uuidString: uuidString)
    }
  }

  public func clearActiveCall(callId: String?) {
    queue.sync {
      var byCallId = defaults.dictionary(forKey: Keys.activeCallsByCallId) as? [String: String] ?? [:]
      var byUuid = defaults.dictionary(forKey: Keys.payloadByUuid) as? [String: [String: String]] ?? [:]

      if let callId, let uuidString = byCallId.removeValue(forKey: callId) {
        byUuid.removeValue(forKey: uuidString)
      }

      defaults.set(byCallId, forKey: Keys.activeCallsByCallId)
      defaults.set(byUuid, forKey: Keys.payloadByUuid)
    }
  }

  public func clearActiveCall(uuid: UUID) {
    queue.sync {
      var byCallId = defaults.dictionary(forKey: Keys.activeCallsByCallId) as? [String: String] ?? [:]
      var byUuid = defaults.dictionary(forKey: Keys.payloadByUuid) as? [String: [String: String]] ?? [:]
      let uuidString = uuid.uuidString
      byUuid.removeValue(forKey: uuidString)
      for (callId, mapped) in byCallId where mapped == uuidString {
        byCallId.removeValue(forKey: callId)
      }
      defaults.set(byCallId, forKey: Keys.activeCallsByCallId)
      defaults.set(byUuid, forKey: Keys.payloadByUuid)
    }
  }

  private func readPendingEventsLocked() -> [[String: Any]] {
    guard let raw = defaults.data(forKey: Keys.pendingEvents) else { return [] }
    guard let decoded = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else {
      return []
    }
    return decoded
  }

  private func writePendingEventsLocked(_ events: [[String: Any]]) {
    guard let data = try? JSONSerialization.data(withJSONObject: events) else { return }
    defaults.set(data, forKey: Keys.pendingEvents)
  }
}
