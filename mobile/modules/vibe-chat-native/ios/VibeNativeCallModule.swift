import ExpoModulesCore

public class VibeNativeCallModule: Module {
  public func definition() -> ModuleDefinition {
    Name("VibeNativeCall")

    Function("isSupported") {
      true
    }

    Function("drainPendingEvents") {
      VibeNativeCallStore.shared.drainEvents()
    }

    Function("getPushTokens") {
      VibeNativeCallStore.shared.getPushTokens()
    }

    Function("clearIncomingCallUi") { (payload: [String: Any]) in
      let callId = (payload["callId"] as? String) ?? (payload["call_id"] as? String)
      VibeNativeCallManager.shared.clearIncomingCallUi(callId: callId)
    }
  }
}

