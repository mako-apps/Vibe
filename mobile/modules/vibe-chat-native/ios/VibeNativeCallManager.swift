import AVFoundation
import CallKit
import Foundation
import PushKit
import UIKit

public final class VibeNativeCallManager: NSObject {
  public static let shared = VibeNativeCallManager()

  private let store = VibeNativeCallStore.shared
  private lazy var provider: CXProvider = {
    let config = CXProviderConfiguration(localizedName: "Vibe")
    config.supportsVideo = true
    config.maximumCallsPerCallGroup = 1
    config.maximumCallGroups = 1
    config.supportedHandleTypes = [.generic]
    config.includesCallsInRecents = false
    return CXProvider(configuration: config)
  }()
  private let callController = CXCallController()
  private var pushRegistry: PKPushRegistry?
  private var started = false

  private override init() {
    super.init()
  }

  public func start() {
    DispatchQueue.main.async {
      guard !self.started else { return }
      self.started = true
      self.provider.setDelegate(self, queue: nil)
      let registry = PKPushRegistry(queue: DispatchQueue.main)
      registry.delegate = self
      registry.desiredPushTypes = [.voIP]
      self.pushRegistry = registry
    }
  }

  public func handleRemoteNotification(userInfo: [AnyHashable: Any]) -> Bool {
    guard let payload = normalizeIncomingCallPayload(userInfo: userInfo) else { return false }
    reportIncomingCall(payload: payload, source: "remoteNotification")
    return true
  }

  public func clearIncomingCallUi(callId: String?) {
    guard let callId, !callId.isEmpty else { return }
    guard let uuid = store.uuid(forCallId: callId) else { return }
    provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
    store.clearActiveCall(callId: callId)
  }

  private func reportIncomingCall(payload: [String: String], source: String) {
    let callId = payload["callId"] ?? UUID().uuidString
    let uuid = store.uuid(forCallId: callId) ?? UUID()
    let update = CXCallUpdate()
    let callerName = payload["fromUserName"] ?? payload["fromUserId"] ?? "Incoming call"
    update.localizedCallerName = callerName
    update.remoteHandle = CXHandle(type: .generic, value: payload["fromUserId"] ?? callerName)
    update.hasVideo = (payload["callType"] ?? "voice") == "video"
    update.supportsHolding = false
    update.supportsGrouping = false
    update.supportsUngrouping = false
    update.supportsDTMF = false

    store.setActiveCall(uuid: uuid, payload: payload)
    store.enqueueEvent(type: "incomingCall", payload: payload + ["nativeSource": source])

    provider.reportNewIncomingCall(with: uuid, update: update) { error in
      if let error {
        NSLog("[VibeNativeCall] reportNewIncomingCall failed callId=%@ error=%@", callId, error.localizedDescription)
      } else {
        NSLog("[VibeNativeCall] reportNewIncomingCall ok callId=%@ uuid=%@", callId, uuid.uuidString)
      }
    }
  }

  private func normalizeIncomingCallPayload(userInfo: [AnyHashable: Any]) -> [String: String]? {
    func string(_ value: Any?) -> String? {
      guard let text = value as? String else { return nil }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }

    func dict(_ value: Any?) -> [String: Any]? {
      if let map = value as? [String: Any] { return map }
      if let map = value as? [AnyHashable: Any] {
        var normalized: [String: Any] = [:]
        for (key, val) in map {
          normalized[String(describing: key)] = val
        }
        return normalized
      }
      if let raw = value as? String,
         let data = raw.data(using: .utf8),
         let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return parsed
      }
      return nil
    }

    let root = userInfo.reduce(into: [String: Any]()) { partial, entry in
      partial[String(describing: entry.key)] = entry.value
    }
    let candidates = [root, dict(root["data"]), dict(root["body"]), dict(root["payload"])].compactMap { $0 }

    func pick(_ keys: [String]) -> String? {
      for candidate in candidates {
        for key in keys {
          if let value = string(candidate[key]) { return value }
        }
      }
      return nil
    }

    let callId = pick(["callId", "call_id", "callUUID", "call_uuid"])
    let fromUserId = pick(["fromUserId", "from_user_id", "callerId", "caller_id", "userId", "user_id"])
    guard let callId, let fromUserId else { return nil }
    let event = (pick(["type", "event"]) ?? "").lowercased()
    let callTypeRaw = (pick(["callType", "call_type"]) ?? "").lowercased()
    let isCallEvent = ["call-start", "call_start", "incoming-call", "incoming_call", "call"].contains(event)
    let hasCallType = callTypeRaw == "voice" || callTypeRaw == "video"
    guard isCallEvent || hasCallType else { return nil }

    var result: [String: String] = [
      "type": "call-start",
      "event": "call-start",
      "callId": callId,
      "fromUserId": fromUserId,
      "fromUserName": pick(["fromUserName", "from_user_name", "callerName", "caller_name", "userName", "user_name"]) ?? fromUserId,
      "callType": callTypeRaw == "video" ? "video" : "voice",
    ]
    if let image = pick(["fromUserImage", "from_user_image", "callerImage", "caller_image", "userImage", "user_image"]) {
      result["fromUserImage"] = image
    }
    return result
  }
}

extension VibeNativeCallManager: PKPushRegistryDelegate {
  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    guard type == .voIP else { return }
    let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    store.setVoipToken(token)
    NSLog("[VibeNativeCall] VoIP token updated len=%d", token.count)
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    guard type == .voIP else { return }
    store.setVoipToken(nil)
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    defer { completion() }
    guard type == .voIP else { return }
    guard let normalized = normalizeIncomingCallPayload(userInfo: payload.dictionaryPayload) else { return }
    reportIncomingCall(payload: normalized, source: "voip")
  }
}

extension VibeNativeCallManager: CXProviderDelegate {
  func providerDidReset(_ provider: CXProvider) {}

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    if let payload = store.payload(for: action.callUUID) {
      store.enqueueEvent(type: "callAction", payload: payload + ["action": "answer"])
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    if let payload = store.payload(for: action.callUUID) {
      store.enqueueEvent(type: "callAction", payload: payload + ["action": "decline"])
      store.clearActiveCall(uuid: action.callUUID)
    }
    action.fulfill()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
