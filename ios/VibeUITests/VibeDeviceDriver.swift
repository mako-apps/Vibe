import XCTest

/// Host-style device driver for physical-iPhone UI tests (Gradle/Espresso analogue).
/// Launches Vibe, taps tabs, opens chats, types, sends, and captures screenshots
/// into the XCResult (and console paths for the agent loop).
final class VibeDeviceDriver {
  let app: XCUIApplication
  private var shotIndex = 0
  private let shotPrefix: String

  init(app: XCUIApplication = XCUIApplication(), shotPrefix: String = "vibe") {
    self.app = app
    self.shotPrefix = shotPrefix
  }

  // MARK: - Lifecycle

  func launch(terminateFirst: Bool = true) {
    if terminateFirst {
      app.terminate()
    }
    app.launchArguments += [
      "-UITesting",
      "1",
      "-AppleLanguages",
      "(en)",
      "-AppleLocale",
      "en_US",
    ]
    app.launch()
    // Auth / home can take a beat on cold launch.
    _ = app.wait(for: .runningForeground, timeout: 20)
    sleepMs(1_200)
  }

  // MARK: - Tabs (Calls · Contacts · Chats · Search · Settings)

  @discardableResult
  func tapTab(_ title: String, timeout: TimeInterval = 8) -> Bool {
    let tab = app.tabBars.buttons[title]
    if waitFor(tab, timeout: timeout) {
      tab.tap()
      sleepMs(600)
      return true
    }
    // Fallback: partial match (localization / SF Symbol only).
    let buttons = app.tabBars.buttons
    let count = buttons.count
    for i in 0..<count {
      let el = buttons.element(boundBy: i)
      if el.label.localizedCaseInsensitiveContains(title) {
        el.tap()
        sleepMs(600)
        return true
      }
    }
    return false
  }

  func goToChats() {
    if tapTab("Chats", timeout: 2) { return }
    // Agent conversations hide the root tab bar. Return to Home first so a
    // multi-agent loop can open the next DM instead of searching inside the
    // conversation it just tested.
    _ = goBackFromChat(timeout: 4)
    _ = tapTab("Chats", timeout: 4)
  }
  func goToCalls() { _ = tapTab("Calls") }
  func goToContacts() { _ = tapTab("Contacts") }
  func goToSettings() { _ = tapTab("Settings") }

  // MARK: - Chat list

  /// Open a chat by visible title (e.g. "Grok", "Claude", "Codex").
  @discardableResult
  func openChat(named title: String, timeout: TimeInterval = 12) -> Bool {
    goToChats()
    sleepMs(500)

    // Prefer cells / static texts with the chat title.
    let cell = app.cells.containing(.staticText, identifier: title).element
    if waitFor(cell, timeout: 2) {
      cell.tap()
      sleepMs(900)
      return true
    }

    let text = app.staticTexts[title]
    if waitFor(text, timeout: timeout) {
      // Tap the row area, not just the tiny label if needed.
      if text.isHittable {
        text.tap()
      } else {
        // Coordinate tap into parent.
        let coord = text.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        coord.tap()
      }
      sleepMs(900)
      return true
    }

    // Scroll home list and retry once.
    let list = app.collectionViews.firstMatch.exists
      ? app.collectionViews.firstMatch
      : app.tables.firstMatch
    if list.exists {
      list.swipeUp()
      sleepMs(400)
      if app.staticTexts[title].waitForExistence(timeout: 4) {
        app.staticTexts[title].tap()
        sleepMs(900)
        return true
      }
    }
    return false
  }

  @discardableResult
  func goBackFromChat(timeout: TimeInterval = 6) -> Bool {
    let back = app.buttons["Back"]
    if waitFor(back, timeout: timeout) {
      back.tap()
      sleepMs(500)
      return true
    }
    // Nav bar first button often is back.
    let navBack = app.navigationBars.buttons.element(boundBy: 0)
    if navBack.exists && navBack.isHittable {
      navBack.tap()
      sleepMs(500)
      return true
    }
    return false
  }

  // MARK: - Composer / send

  /// Type into the chat composer (TextView or TextField) and optionally send.
  @discardableResult
  func typeMessage(_ text: String, send: Bool = true, timeout: TimeInterval = 10) -> Bool {
    let field = firstComposer(timeout: timeout)
    guard let field else {
      NSLog("[VibeUI] composer not found; dumping hierarchy")
      logHierarchySnippet()
      return false
    }

    // Force focus even when isHittable is false (common with layered glass composers).
    if field.isHittable {
      field.tap()
    } else {
      field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    sleepMs(350)
    // Clear existing draft if any (value often equals placeholder when empty).
    if let value = field.value as? String, !value.isEmpty {
      let looksLikePlaceholder =
        value.localizedCaseInsensitiveContains("message")
        || value.localizedCaseInsensitiveContains("type")
      if !looksLikePlaceholder {
        field.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 1) {
          app.menuItems["Select All"].tap()
          field.typeText(text)
          sleepMs(400)
          if send {
            return tapSend()
          }
          return true
        }
      }
    }
    field.typeText(text)
    sleepMs(400)

    guard send else { return true }
    return tapSend()
  }

  @discardableResult
  private func tapSend() -> Bool {
    let candidates: [XCUIElement] = [
      app.buttons["chat.send"],
      app.buttons["Send"],
      app.buttons["Stop response"],
    ]
    for sendBtn in candidates {
      if sendBtn.waitForExistence(timeout: 2) {
        if sendBtn.isHittable {
          sendBtn.tap()
        } else {
          sendBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        sleepMs(800)
        return true
      }
    }
    // Keyboard return as last resort.
    if app.keyboards.buttons["return"].exists {
      app.keyboards.buttons["return"].tap()
      sleepMs(800)
      return true
    }
    return false
  }

  private func firstComposer(timeout: TimeInterval) -> XCUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      // Prefer stable ids we stamp on ChatInputBar.
      let byId = app.textViews["chat.composer"]
      if byId.exists { return byId }
      let byLabel = app.textViews["Message"]
      if byLabel.exists { return byLabel }

      // Do not fall back to arbitrary text views: history transcripts contain
      // read-only text views and selecting one would make a false follow-up send.
      let tfs = app.textFields
      let tfCount = tfs.count
      for i in 0..<tfCount {
        let tf = tfs.element(boundBy: i)
        if tf.exists { return tf }
      }
      // Search fields / other editable surfaces.
      let search = app.searchFields.element(boundBy: 0)
      if search.exists { return search }
      sleepMs(250)
    }
    return nil
  }

  // MARK: - History / agent chrome

  @discardableResult
  func openHistory(timeout: TimeInterval = 8) -> Bool {
    let history = app.buttons["chat.history"].exists
      ? app.buttons["chat.history"]
      : app.buttons["History"]
    if waitFor(history, timeout: timeout) {
      history.tap()
      sleepMs(900)
      return true
    }
    return false
  }

  @discardableResult
  func openNewChat(timeout: TimeInterval = 6) -> Bool {
    let btn = app.buttons["chat.new"].exists
      ? app.buttons["chat.new"]
      : app.buttons["New Chat"]
    if waitFor(btn, timeout: timeout) {
      btn.tap()
      sleepMs(700)
      return true
    }
    return false
  }

  /// Tap a history session row by topic substring.
  @discardableResult
  func openHistorySession(matching topic: String, timeout: TimeInterval = 10) -> Bool {
    let pred = NSPredicate(format: "label CONTAINS[c] %@", topic)
    let row = app.descendants(matching: .any).matching(pred).element(boundBy: 0)
    if waitFor(row, timeout: timeout) {
      row.tap()
      sleepMs(1_200)
      return true
    }
    return false
  }

  // MARK: - Screenshots

  @discardableResult
  func screenshot(_ name: String, test: XCTestCase) -> String {
    shotIndex += 1
    let label = String(format: "%@_%02d_%@", shotPrefix, shotIndex, sanitize(name))
    let shot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: shot)
    attachment.name = label
    attachment.lifetime = .keepAlways
    test.add(attachment)

    // Write PNG into the test-runner temp dir (surfaces in device logs / attachments).
    let data = shot.pngRepresentation
    let tmp = NSTemporaryDirectory() as NSString
    let path = tmp.appendingPathComponent("\(label).png")
    try? data.write(to: URL(fileURLWithPath: path))
    NSLog("[VibeUI] screenshot wrote path=%@ bytes=%d", path, data.count)
    NSLog("[VibeUI] screenshot name=%@", label)
    return label
  }

  // MARK: - Helpers

  @discardableResult
  func waitFor(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    element.waitForExistence(timeout: timeout)
  }

  func sleepMs(_ ms: UInt32) {
    usleep(ms * 1000)
  }

  @discardableResult
  func waitForExactText(_ text: String, timeout: TimeInterval) -> Bool {
    app.staticTexts[text].waitForExistence(timeout: timeout)
  }

  func exactTextCount(_ text: String) -> Int {
    app.staticTexts.matching(NSPredicate(format: "label == %@", text)).count
  }

  @discardableResult
  func waitForButton(identifier: String, timeout: TimeInterval) -> Bool {
    app.buttons[identifier].waitForExistence(timeout: timeout)
  }

  @discardableResult
  func tapButton(identifier: String, timeout: TimeInterval = 4) -> Bool {
    let button = app.buttons[identifier]
    guard button.waitForExistence(timeout: timeout) else { return false }
    if button.isHittable {
      button.tap()
    } else {
      button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    return true
  }

  private func sanitize(_ name: String) -> String {
    name
      .replacingOccurrences(of: " ", with: "_")
      .replacingOccurrences(of: "/", with: "-")
      .lowercased()
  }

  /// Dump a short hierarchy for debugging when a control is missing.
  func logHierarchySnippet() {
    NSLog("[VibeUI] hierarchy debugDescription length=%d", app.debugDescription.count)
    // First 4k only — full dump is huge.
    let desc = app.debugDescription
    let snippet = String(desc.prefix(4000))
    NSLog("[VibeUI] hierarchy snippet:\n%@", snippet)
  }
}
