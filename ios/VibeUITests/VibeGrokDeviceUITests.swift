import XCTest

/// Comprehensive on-device UI loop: tabs → Chats → Grok → History → follow-up send.
/// Run on physical phone:
/// ```
/// xcodebuild test -project ios/Vibe.xcodeproj -scheme Vibe \
///   -destination 'platform=iOS,id=00008140-000935000288801C' \
///   -only-testing:VibeUITests/VibeGrokDeviceUITests \
///   -derivedDataPath /tmp/vibe-uitest \
///   -allowProvisioningUpdates
/// ```
final class VibeGrokDeviceUITests: XCTestCase {
  var driver: VibeDeviceDriver!

  override func setUpWithError() throws {
    continueAfterFailure = true
    driver = VibeDeviceDriver(shotPrefix: "grok_loop")
    driver.launch(terminateFirst: true)
  }

  override func tearDownWithError() throws {
    driver = nil
  }

  func test_01_tabs_and_home_screenshots() throws {
    XCTAssertTrue(driver.tapTab("Chats"), "Chats tab should exist")
    _ = driver.screenshot("chats_home", test: self)

    XCTAssertTrue(driver.tapTab("Calls"), "Calls tab")
    _ = driver.screenshot("calls_tab", test: self)

    XCTAssertTrue(driver.tapTab("Contacts"), "Contacts tab")
    _ = driver.screenshot("contacts_tab", test: self)

    XCTAssertTrue(driver.tapTab("Settings"), "Settings tab")
    _ = driver.screenshot("settings_tab", test: self)

    // Back to Chats for the rest of the suite.
    XCTAssertTrue(driver.tapTab("Chats"), "return Chats")
    _ = driver.screenshot("chats_home_again", test: self)
  }

  func test_02_open_grok_and_capture() throws {
    driver.goToChats()
    _ = driver.screenshot("before_open_grok", test: self)

    let opened = driver.openChat(named: "Grok")
    if !opened {
      // Fallbacks: other agent names sometimes shown with handle.
      let alt =
        driver.openChat(named: "grok")
        || driver.openChat(named: "@grok")
      if !alt {
        driver.logHierarchySnippet()
        _ = driver.screenshot("grok_not_found", test: self)
        XCTFail("Could not open Grok chat from home list")
        return
      }
    }

    _ = driver.screenshot("grok_chat_open", test: self)

    // Composer should be present in a bridge DM.
    let typed = driver.typeMessage(
      "UITest probe \(Int(Date().timeIntervalSince1970)): reply with only PONG",
      send: true
    )
    _ = driver.screenshot("after_send_followup", test: self)
    XCTAssertTrue(typed, "Should type+send a follow-up in Grok DM")

    // Give the bridge a few seconds to stream a reply frame.
    driver.sleepMs(5_000)
    _ = driver.screenshot("after_stream_wait", test: self)
  }

  func test_03_history_session_and_followup() throws {
    driver.goToChats()
    guard driver.openChat(named: "Grok") || driver.openChat(named: "grok") else {
      driver.logHierarchySnippet()
      XCTFail("Grok chat missing")
      return
    }
    _ = driver.screenshot("history_entry_chat", test: self)

    XCTAssertTrue(driver.openHistory(), "History should be available for a Grok DM")
    _ = driver.screenshot("history_list", test: self)

    // This is the fresh desktop session created for the device loop. Never use a
    // generic fallback: that hides session-isolation regressions by resuming a
    // different conversation.
    let opened = driver.openHistorySession(matching: "Vibe Mobile QA 2026")
    _ = driver.screenshot(opened ? "history_session_open" : "history_session_miss", test: self)
    XCTAssertTrue(opened, "The desktop QA session should be selectable from History")
    guard opened else { return }

    let ok = driver.typeMessage(
      "history-followup \(Int(Date().timeIntervalSince1970)): say only OK",
      send: true
    )
    _ = driver.screenshot("history_followup_sent", test: self)
    XCTAssertTrue(ok, "Follow-up from History should send")
    driver.sleepMs(6_000)
    _ = driver.screenshot("history_followup_after_wait", test: self)
  }

  func test_04_new_chat_task_flow() throws {
    driver.goToChats()
    guard driver.openChat(named: "Grok") || driver.openChat(named: "grok") else {
      XCTFail("Grok missing for new-chat flow")
      return
    }

    if driver.openNewChat() {
      _ = driver.screenshot("new_chat_blank", test: self)
    } else {
      _ = driver.screenshot("new_chat_button_missing", test: self)
    }

    let ok = driver.typeMessage(
      "new-task UITest: reply with only READY2",
      send: true
    )
    XCTAssertTrue(ok)
    _ = driver.screenshot("new_task_sent", test: self)
    driver.sleepMs(6_000)
    _ = driver.screenshot("new_task_stream", test: self)
  }

  func test_05_agent_followups_route_and_render() throws {
    for agent in ["Codex", "Claude", "Grok", "Agy"] {
      driver.goToChats()
      let opened: Bool
      if agent == "Agy" {
        opened = driver.openChat(named: agent) || driver.openChat(named: "Antigravity")
      } else {
        opened = driver.openChat(named: agent) || driver.openChat(named: agent.lowercased())
      }
      guard opened else {
        driver.logHierarchySnippet()
        _ = driver.screenshot("\(agent.lowercased())_missing", test: self)
        XCTFail("\(agent) chat should be available for the bridge follow-up loop")
        continue
      }

      _ = driver.screenshot("\(agent.lowercased())_before_followup", test: self)
      let token = "ACK-\(agent.uppercased())-\(Int(Date().timeIntervalSince1970))"
      let sent = driver.typeMessage(
        "Mobile follow-up. Reply with exactly \(token) and nothing else.",
        send: true
      )
      _ = driver.screenshot("\(agent.lowercased())_followup_sent", test: self)
      XCTAssertTrue(sent, "\(agent) follow-up should reach its own conversation")
      XCTAssertTrue(
        driver.waitForExactText(token, timeout: 35),
        "\(agent) should render its routed response on the phone")
      driver.sleepMs(2_000)
      _ = driver.screenshot("\(agent.lowercased())_followup_settled", test: self)
      XCTAssertEqual(
        driver.exactTextCount(token), 1,
        "\(agent) must render one settled agent response, not a duplicate")
    }
  }

  /// External harness writes one harmless command request to ~/.vibe/ask.sock while
  /// this test is waiting. The sheet must remain available until the phone approves it.
  func test_06_claude_command_approval_waits_for_mobile() throws {
    driver.goToChats()
    guard driver.openChat(named: "Claude") || driver.openChat(named: "claude") else {
      XCTFail("Claude chat missing")
      return
    }
    _ = driver.screenshot("claude_waiting_for_command", test: self)
    XCTAssertTrue(
      driver.waitForButton(identifier: "agent.ask.approve", timeout: 90),
      "Command approval should arrive and remain on mobile")
    _ = driver.screenshot("claude_command_approval", test: self)
    XCTAssertTrue(driver.tapButton(identifier: "agent.ask.approve"))
  }

  /// External harness writes an ask_user payload to ~/.vibe/ask.sock while waiting.
  func test_07_claude_ask_user_waits_for_mobile() throws {
    driver.goToChats()
    guard driver.openChat(named: "Claude") || driver.openChat(named: "claude") else {
      XCTFail("Claude chat missing")
      return
    }
    _ = driver.screenshot("claude_waiting_for_ask_user", test: self)
    XCTAssertTrue(
      driver.waitForButton(identifier: "agent.ask.submit", timeout: 90),
      "ask_user should arrive and remain on mobile")
    XCTAssertTrue(driver.tapButton(identifier: "agent.ask.option.0.0"))
    _ = driver.screenshot("claude_ask_user", test: self)
    XCTAssertTrue(driver.tapButton(identifier: "agent.ask.submit"))
  }
}
