import Foundation

final class ChatEngineStore {
  static let shared = ChatEngineStore()

  private let defaults = UserDefaults.standard
  private let queue = DispatchQueue(label: "vibe.chat.engine.store")
  private let configKey = "vibe.chat.engine.config.v1"
  private let journalKey = "vibe.chat.engine.journal.v1"
  private let outboundKey = "vibe.chat.engine.outbound.v1"
  private let maxJournalCount = 300

  private init() {}

  func setConfig(_ payload: [String: Any]) {
    queue.sync {
      // Migrate sensitive values (private keys, auth tokens) to Keychain,
      // replacing them with sentinels in the plaintext config blob.
      let sanitized = SecureKeyStore.shared.migrateAndSanitize(payload)
      guard JSONSerialization.isValidJSONObject(sanitized),
            let data = try? JSONSerialization.data(withJSONObject: sanitized)
      else { return }
      self.defaults.set(data, forKey: self.configKey)
    }
  }

  func getConfig() -> [String: Any] {
    queue.sync {
      loadConfigLocked()
    }
  }

  func updateConfig(_ changes: [String: Any?]) {
    queue.sync {
      updateConfigLocked(changes)
    }
  }

  func updateConfigAsync(_ changes: [String: Any?], completion: (() -> Void)? = nil) {
    queue.async {
      self.updateConfigLocked(changes)
      completion?()
    }
  }

  func clearConfig() {
    queue.sync {
      defaults.removeObject(forKey: configKey)
      SecureKeyStore.sensitiveKeys.forEach { SecureKeyStore.shared.deleteSecret(key: $0) }
    }
  }

  /// One-time migration: packet mesh is now opt-in (default direct). Sessions
  /// persisted before this change still carry transportMode=packet_mesh, which
  /// blocks large media (music/video/files) and makes sends fail immediately.
  /// Downgrade such sessions to direct exactly once; after this runs,
  /// Settings → Connection remains the source of truth and can re-enable mesh
  /// without being undone on the next launch.
  func migrateLegacyPacketMeshToDirectIfNeeded() {
    let flagKey = "vibe.mesh.legacyDowngradeDone.v1"
    queue.sync {
      guard !defaults.bool(forKey: flagKey) else { return }
      defaults.set(true, forKey: flagKey)
      var current = loadConfigLocked()
      let mode = (current["transportMode"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard mode == "packet_mesh" else { return }
      current["transportMode"] = "direct"
      current["packetStatus"] = "direct"
      current.removeValue(forKey: "packetProxyPort")
      let sanitized = SecureKeyStore.shared.migrateAndSanitize(current)
      guard JSONSerialization.isValidJSONObject(sanitized),
            let data = try? JSONSerialization.data(withJSONObject: sanitized)
      else { return }
      defaults.set(data, forKey: configKey)
      NSLog("[ChatEngineStore] migrated legacy transportMode packet_mesh -> direct")
    }
  }

  func appendJournal(_ entry: [String: Any]) {
    queue.async {
      var items = self.loadJournalLocked()
      items.append(entry)
      if items.count > self.maxJournalCount {
        items = Array(items.suffix(self.maxJournalCount))
      }
      self.saveJournalLocked(items)
    }
  }

  func getJournal(limit: Int? = nil) -> [[String: Any]] {
    queue.sync {
      let items = loadJournalLocked()
      if let limit, limit > 0, items.count > limit {
        return Array(items.suffix(limit))
      }
      return items
    }
  }

  func clearJournal() {
    queue.async {
      self.defaults.removeObject(forKey: self.journalKey)
    }
  }

  func setOutboundState(_ payload: [String: Any]) {
    queue.async {
      guard JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload)
      else { return }
      self.defaults.set(data, forKey: self.outboundKey)
    }
  }

  func getOutboundState() -> [String: Any] {
    queue.sync {
      guard let data = defaults.data(forKey: outboundKey),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return [:] }
      return obj
    }
  }

  func clearOutboundState() {
    queue.async {
      self.defaults.removeObject(forKey: self.outboundKey)
    }
  }

  private func loadJournalLocked() -> [[String: Any]] {
    guard let data = defaults.data(forKey: journalKey),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return obj
  }

  private func loadConfigLocked() -> [String: Any] {
    guard let data = defaults.data(forKey: configKey),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return SecureKeyStore.shared.reassemble(obj)
  }

  private func updateConfigLocked(_ changes: [String: Any?]) {
    var current = loadConfigLocked()
    for (key, value) in changes {
      if let value {
        current[key] = value
      } else {
        current.removeValue(forKey: key)
        if SecureKeyStore.sensitiveKeys.contains(key) {
          SecureKeyStore.shared.deleteSecret(key: key)
        }
      }
    }

    let sanitized = SecureKeyStore.shared.migrateAndSanitize(current)
    guard JSONSerialization.isValidJSONObject(sanitized),
          let data = try? JSONSerialization.data(withJSONObject: sanitized)
    else { return }
    defaults.set(data, forKey: configKey)
  }

  private func saveJournalLocked(_ items: [[String: Any]]) {
    guard JSONSerialization.isValidJSONObject(items),
          let data = try? JSONSerialization.data(withJSONObject: items)
    else { return }
    defaults.set(data, forKey: journalKey)
  }
}
