import ExpoModulesCore

public class ChatNativeGifModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ChatNativeGif")

    Function("isSupported") {
      true
    }

    Function("supportsNativeGifPanel") {
      true
    }

    Function("setApiKey") { (apiKey: String) in
      let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      ChatGifPanelConfig.shared.apiKey = trimmed
    }

    Function("getApiKey") {
      ChatGifPanelConfig.shared.apiKey
    }
  }
}
