import ExpoModulesCore

public class VibeNativeCallModule: Module {
  public override init() {
    super.init()
    VibeNativeCallUiCoordinator.shared.attach(module: self)
  }

  deinit {
    VibeNativeCallUiCoordinator.shared.detach(module: self)
  }

  public func definition() -> ModuleDefinition {
    Name("VibeNativeCall")

    Events("onCallUiEvent")

    Function("isSupported") {
      true
    }

    Function("supportsInAppUi") {
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

    Function("setCallUiState") { (payload: [String: Any]) in
      VibeNativeCallUiCoordinator.shared.setState(payload)
    }

    Function("hideCallUi") {
      VibeNativeCallUiCoordinator.shared.hide()
    }
  }

  func emitCallUiEvent(_ payload: [String: Any]) {
    sendEvent("onCallUiEvent", payload)
  }
}
