import SwiftUI
import UIKit
import WebKit
import OSLog
import Darwin
import Combine

enum AppUITrace {
  static let subsystem = "com.mohammadshayani.vibe.native"
  private static let logger = Logger(subsystem: subsystem, category: "UITrace")

  static func notice(_ message: String) {
    logger.notice("\(message, privacy: .public)")
  }

  static func error(_ message: String) {
    logger.error("\(message, privacy: .public)")
    NSLog("[VibeUITrace][error] %@", message)
  }

  static func fault(_ message: String) {
    logger.fault("\(message, privacy: .public)")
    NSLog("[VibeUITrace][fault] %@", message)
  }
}

final class AppUIStallWatchdog {
  static let shared = AppUIStallWatchdog()

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.mohammadshayani.vibe.ui-stall-watchdog", qos: .utility)
  private let stallThresholdSeconds: TimeInterval = 2.0
  private var timer: DispatchSourceTimer?
  private var started = false
  private var active = false
  private var lastMainBeatAt = ProcessInfo.processInfo.systemUptime
  private var latestContext = "launch"
  private var lastReportedStallBucket = -1
  private var wasStalled = false
  /// Mach port for the main thread, captured on the main thread itself. Lets the
  /// background watchdog read the main thread's run-state during a stall to tell
  /// a busy-loop (run=running, high cpu) apart from a blocking wait (run=waiting).
  private var mainMachThread: mach_port_t = 0

  private init() {}

  func start(context: String) {
    var shouldStart = false
    locked {
      latestContext = context
      active = true
      lastMainBeatAt = ProcessInfo.processInfo.systemUptime
      if !started {
        started = true
        shouldStart = true
      }
    }
    guard shouldStart else { return }
    AppUITrace.notice("watchdog start thresholdMs=\(Int(stallThresholdSeconds * 1000)) context=\(context)")
    scheduleMainBeat()

    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(deadline: .now() + 1.0, repeating: 0.75)
    source.setEventHandler { [weak self] in
      self?.checkForStall()
    }
    locked {
      timer = source
    }
    source.resume()
  }

  func setActive(_ isActive: Bool, context: String) {
    locked {
      active = isActive
      latestContext = context
      lastMainBeatAt = ProcessInfo.processInfo.systemUptime
      lastReportedStallBucket = -1
      wasStalled = false
    }
    AppUITrace.notice("watchdog active=\(isActive ? "Y" : "N") context=\(context)")
  }

  func updateContext(_ context: String) {
    locked {
      latestContext = context
    }
  }

  private func scheduleMainBeat() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self else { return }
      self.recordMainBeat()
      self.scheduleMainBeat()
    }
  }

  private func recordMainBeat() {
    let now = ProcessInfo.processInfo.systemUptime
    let recovered: (blockedMs: Int, context: String)? = locked {
      if mainMachThread == 0 {
        mainMachThread = pthread_mach_thread_np(pthread_self())
      }
      let elapsed = now - lastMainBeatAt
      lastMainBeatAt = now
      lastReportedStallBucket = -1
      guard active, wasStalled else { return nil }
      wasStalled = false
      return (Int(elapsed * 1000), latestContext)
    }
    if let recovered {
      AppUITrace.error(
        "main-thread-recovered blockedMs=\(recovered.blockedMs) context=\(recovered.context)"
      )
    }
  }

  private func checkForStall() {
    let now = ProcessInfo.processInfo.systemUptime
    let stalled: (blockedMs: Int, context: String, first: Bool)? = locked {
      guard active else { return nil }
      let elapsed = now - lastMainBeatAt
      guard elapsed >= stallThresholdSeconds else { return nil }
      let bucket = Int(elapsed)
      guard bucket != lastReportedStallBucket else { return nil }
      lastReportedStallBucket = bucket
      let first = !wasStalled
      wasStalled = true
      return (Int(elapsed * 1000), latestContext, first)
    }
    guard let stalled else { return }
    AppUITrace.fault(
      "main-thread-stall blockedMs=\(stalled.blockedMs) context=\(stalled.context)"
    )
    // Probe the main thread's scheduler state once per stall episode. This is the
    // single fact the context label can't give us: whether main is BURNING CPU
    // (run=running → infinite loop / runaway layout) or PARKED (run=waiting →
    // blocked on a synchronous network/lock/FFI call). It narrows the hunt before
    // a full `sample`/Instruments capture pins the exact frame.
    if stalled.first {
      AppUITrace.fault("main-thread-stall \(mainThreadStateDescription())")
      AppUITrace.fault("main-thread-stall backtrace:\n\(captureMainThreadStack())")
    }
  }

  /// Read-only snapshot of the main thread's run-state and CPU usage via
  /// `thread_info`. Safe to call from the watchdog queue — it does not suspend
  /// the thread or walk its stack.
  private func mainThreadStateDescription() -> String {
    let machThread = locked { mainMachThread }
    guard machThread != 0 else { return "threadState=unavailable" }
    var info = thread_basic_info()
    // THREAD_BASIC_INFO_COUNT is a compound C macro that doesn't import into
    // Swift; derive the integer-word count from the struct size instead.
    var count = mach_msg_type_number_t(
      MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        thread_info(machThread, thread_flavor_t(THREAD_BASIC_INFO), rebound, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return "threadState=error(kr=\(kr))" }
    let runLabel: String
    switch Int32(info.run_state) {
    case TH_STATE_RUNNING: runLabel = "running"
    case TH_STATE_STOPPED: runLabel = "stopped"
    case TH_STATE_WAITING: runLabel = "waiting"
    case TH_STATE_UNINTERRUPTIBLE: runLabel = "uninterruptible"
    case TH_STATE_HALTED: runLabel = "halted"
    default: runLabel = "unknown(\(info.run_state))"
    }
    let idle = (Int32(info.flags) & TH_FLAGS_IDLE) != 0
    let hint =
      runLabel == "running"
      ? "likely-infinite-loop" : (runLabel == "waiting" ? "likely-blocking-wait" : "?")
    return
      "threadState run=\(runLabel) cpu=\(info.cpu_usage)/\(TH_USAGE_SCALE) idle=\(idle ? "Y" : "N") hint=\(hint)"
  }

  /// Capture the main thread's call stack during a stall and symbolicate it.
  ///
  /// Safety: while the main thread is suspended we do ZERO heap allocation and
  /// only issue `vm_read_overwrite` (a mach trap that cannot take the malloc
  /// lock). The frame buffer is pre-reserved before the suspend, and `dladdr`
  /// symbolication (which may allocate) runs only after the thread is resumed —
  /// otherwise, if main were suspended inside malloc, the watchdog could deadlock
  /// and never resume it.
  private func captureMainThreadStack() -> String {
    let machThread = locked { mainMachThread }
    guard machThread != 0 else { return "stack=unavailable" }

    var addresses: [UInt] = []
    addresses.reserveCapacity(64)

    guard thread_suspend(machThread) == KERN_SUCCESS else {
      return "stack=suspend-failed"
    }

    var pc: UInt = 0
    var fp: UInt = 0
    var stateOK = false
    #if arch(arm64)
    var state = arm_thread_state64_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &state) { pointer in
      pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
          thread_get_state(machThread, thread_state_flavor_t(thread_flavor_t(ARM_THREAD_STATE64)), rebound, &count)
      }
    }
    if kr == KERN_SUCCESS {
      // Strip arm64e pointer-authentication bits (top 16) so dladdr resolves.
      pc = UInt(state.__pc) & 0x0000_FFFF_FFFF_FFFF
      fp = UInt(state.__fp)
      stateOK = true
    }
    #elseif arch(x86_64)
    var state = x86_thread_state64_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &state) { pointer in
      pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
        thread_get_state(machThread, thread_state_flavor_t(x86_THREAD_STATE64), rebound, &count)
      }
    }
    if kr == KERN_SUCCESS {
      pc = UInt(state.__rip)
      fp = UInt(state.__rbp)
      stateOK = true
    }
    #endif

    if stateOK {
      addresses.append(pc)
      var currentFP = fp
      var depth = 0
      while currentFP != 0, depth < 48 {
        guard let savedFP = readWord(at: currentFP),
          let retAddr = readWord(at: currentFP + UInt(MemoryLayout<UInt>.size))
        else { break }
        if retAddr == 0 { break }
        addresses.append(retAddr & 0x0000_FFFF_FFFF_FFFF)
        if savedFP <= currentFP { break }  // stack grows down; saved FP is higher
        currentFP = savedFP
        depth += 1
      }
    }

    thread_resume(machThread)  // resume BEFORE symbolication (dladdr may allocate)

    guard stateOK else { return "stack=state-failed" }
    let lines = addresses.enumerated().map { index, address in
      symbolicate(address: address, frame: index)
    }
    return lines.joined(separator: "\n")
  }

  /// Read one machine word from this process's memory without crashing on a bad
  /// address (`vm_read_overwrite` returns an error instead of faulting).
  private func readWord(at address: UInt) -> UInt? {
    var value: UInt = 0
    var outSize: vm_size_t = 0
    let kr = withUnsafeMutableBytes(of: &value) { raw -> kern_return_t in
      guard let base = raw.baseAddress else { return KERN_FAILURE }
      return vm_read_overwrite(
        mach_task_self_,
        vm_address_t(address),
        vm_size_t(raw.count),
        vm_address_t(UInt(bitPattern: base)),
        &outSize)
    }
    return (kr == KERN_SUCCESS && outSize == vm_size_t(MemoryLayout<UInt>.size)) ? value : nil
  }

  private func symbolicate(address: UInt, frame: Int) -> String {
    var info = Dl_info()
    if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
      let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
      let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
      let symBase = UInt(bitPattern: info.dli_saddr)
      let offset = address >= symBase ? address - symBase : 0
      return "\(frame)  \(image)  \(symbol) + \(offset)"
    }
    return "\(frame)  ???  0x" + String(address, radix: 16)
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private func appShellRouteLog(_ message: String) {
  let tagged = "[AppShellRoute] \(message)"
  if Thread.isMainThread {
    AppUIStallWatchdog.shared.updateContext(tagged)
  }
  AppUITrace.notice(tagged)
}

enum AppShellTab: Hashable {
  case contacts
  case calls
  case chats
  case settings
  case search
}

struct ChatRoute: Identifiable, Hashable {
  let chatId: String
  let title: String
  let peerUserId: String?
  /// Non-nil when this chat talks to an AI agent's shadow user. Carried into the
  /// engine binding so outgoing messages are routed to the agent backend instead
  /// of being E2E-encrypted to a human peer.
  let peerAgentId: String?
  /// True when this route opens a "talk to the agent" chat (header shows the
  /// agent name). Independent of `peerAgentId` so the always-available fallback
  /// surface can present as an agent chat before an agent id is known.
  let isAgent: Bool
  let avatarURI: String?
  let isGroup: Bool
  let unreadCount: Int
  let initialRows: [[String: Any]]
  /// Attached agent's event-inbox mode (`per_event` / `batched_summary`). Drives
  /// whether the chat view hides agent event notifications behind the Inbox banner.
  let agentEventInboxMode: String?
  /// `"claude"` / `"codex"` when this chat talks to a computer-bridge agent. Drives
  /// the connect-state gate in the chat view: when no paired computer is online the
  /// composer is hidden and a Connect panel is shown instead.
  let bridgeProvider: String?

  var id: String { chatId }

  /// Reserved shadow-user ids for the two computer-bridge agents (seeded server-side).
  static let claudeAgentUserId = "11111111-1111-1111-1111-111111111111"
  static let codexAgentUserId = "22222222-2222-2222-2222-222222222222"

  /// Resolves the bridge provider for a chat. The reserved user ids are the strong
  /// signal; the name is only consulted for confirmed agent users so a human named
  /// "claude" never trips the gate.
  static func resolveBridgeProvider(
    peerUserId: String?,
    name: String?,
    isAgent: Bool,
    agentId: String? = nil
  ) -> String? {
    let pid = peerUserId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if pid == claudeAgentUserId { return "claude" }
    if pid == codexAgentUserId { return "codex" }
    let aid = agentId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch aid {
    case "claude", claudeAgentUserId:
      return "claude"
    case "codex", codexAgentUserId:
      return "codex"
    default:
      break
    }
    guard isAgent else { return nil }
    switch name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "claude": return "claude"
    case "codex": return "codex"
    default: return nil
    }
  }

  /// Display name for a bridge provider id.
  static func bridgeDisplayName(for provider: String) -> String {
    switch provider.lowercased() {
    case "claude": return "Claude"
    case "codex": return "Codex"
    default: return provider.capitalized
    }
  }

  /// True when this route opens a "talk to the agent" chat.
  var isAgentChat: Bool { isAgent }

  /// True when the attached agent runs in inbox (batched summary) mode, so its
  /// event notifications should be surfaced via the Inbox banner instead of
  /// cluttering the transcript.
  var isAgentInboxMode: Bool {
    switch agentEventInboxMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "batched_summary", "batched", "batch", "summary":
      return true
    default:
      return false
    }
  }

  var isBuiltInAgentSurface: Bool {
    ChatHomeListRow.isBuiltInAgentChatId(chatId)
  }

  /// Whether this chat is handled locally (no server Phoenix channel). True for
  /// Saved Messages.
  var skipsServerChannel: Bool {
    chatId == "saved_messages" || isBuiltInAgentSurface
  }

  init(
    chatId: String,
    title: String,
    peerUserId: String?,
    peerAgentId: String? = nil,
    isAgent: Bool = false,
    avatarURI: String?,
    isGroup: Bool,
    unreadCount: Int = 0,
    initialRows: [[String: Any]],
    agentEventInboxMode: String? = nil,
    bridgeProvider: String? = nil
  ) {
    self.chatId = chatId
    self.title = title
    self.peerUserId = peerUserId
    self.peerAgentId = peerAgentId
    let resolvedIsAgent = isAgent || (peerAgentId.map { !$0.isEmpty } ?? false)
    self.isAgent = resolvedIsAgent
    self.avatarURI = avatarURI
    self.isGroup = isGroup
    self.unreadCount = max(0, unreadCount)
    self.initialRows = initialRows
    self.agentEventInboxMode = agentEventInboxMode
    self.bridgeProvider =
      bridgeProvider
      ?? Self.resolveBridgeProvider(
        peerUserId: peerUserId,
        name: title,
        isAgent: resolvedIsAgent,
        agentId: peerAgentId
      )
  }

  init(row: ChatHomeListRow) {
    let resolvedBridge = ChatRoute.resolveBridgeProvider(
      peerUserId: row.peerUserId,
      name: row.title,
      isAgent: row.isAgentFriend,
      agentId: row.peerAgentId
    )
    let cachedRows = resolvedBridge == nil
      ? (row.initialMessages.isEmpty ? row.previewRows : row.initialMessages)
      : []
    NSLog(
      "[AgentRoute] ChatRoute(row:) chatId=%@ title=%@ peerUserId=%@ peerAgentId=%@ isAgentFriend=%@ resolvedBridge=%@",
      row.chatId, row.title, row.peerUserId ?? "nil", row.peerAgentId ?? "nil",
      row.isAgentFriend ? "true" : "false", resolvedBridge ?? "nil")
    self.init(
      chatId: row.chatId,
      title: row.title,
      peerUserId: row.peerUserId,
      peerAgentId: row.peerAgentId,
      isAgent: row.isAgentFriend,
      avatarURI: row.avatarUri,
      isGroup: row.isGroup,
      unreadCount: row.unreadCount,
      initialRows: cachedRows,
      agentEventInboxMode: row.agentEventInboxMode,
      bridgeProvider: resolvedBridge
    )
  }

  static func savedMessages(initialRows: [[String: Any]] = []) -> ChatRoute {
    ChatRoute(
      chatId: "saved_messages",
      title: "Saved Messages",
      peerUserId: nil,
      peerAgentId: nil,
      avatarURI: nil,
      isGroup: false,
      unreadCount: 0,
      initialRows: initialRows
    )
  }

  static func == (lhs: ChatRoute, rhs: ChatRoute) -> Bool {
    lhs.chatId == rhs.chatId && lhs.peerUserId == rhs.peerUserId
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(chatId)
    hasher.combine(peerUserId)
  }
}

struct PresentedChatRoute: Identifiable, Hashable {
  let requestID: Int
  let route: ChatRoute

  var id: Int { requestID }
}

struct PresentedChatProfileRoute: Identifiable, Hashable {
  let requestID: Int
  let route: ChatRoute

  var id: Int { requestID }
}

enum AppChatNavigationAction {
  case avatar
}

@MainActor
private enum NativeCallRouteBridge {
  @discardableResult
  static func startOutgoing(route: ChatRoute, callType: String) -> [String: Any]? {
    guard route.chatId != "saved_messages",
      let toUserId = normalizedString(route.peerUserId)
    else {
      AppToastController.shared.show("Calls are available in direct chats.")
      return nil
    }
    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("The current session is unavailable.")
      return nil
    }

    VibeNativeCallManager.shared.start()
    _ = VibeNativeCallEngine.shared.configure(config.payload)
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let callId = "call_\(now)_\(UUID().uuidString.prefix(8))"
    let payload: [String: Any] = [
      "event": "call-start",
      "callId": callId,
      "callType": callType == "video" ? "video" : "voice",
      "toUserId": toUserId,
      "toUserName": route.title,
      "toUserImage": route.avatarURI ?? "",
      "chatId": route.chatId,
    ]
    let status = VibeNativeCallEngine.shared.startOutgoing(payload)
    VibeNativeCallOverlayPresenter.shared.showOutgoing(payload: payload, status: status)
    let accepted = (status["signalingAccepted"] as? Bool) ?? true
    if !accepted {
      AppToastController.shared.show("Could not start call.")
    }
    return status
  }

  private static func normalizedString(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

@MainActor
private final class VibeNativeCallOverlayPresenter {
  static let shared = VibeNativeCallOverlayPresenter()

  private var observer: NSObjectProtocol?
  private var window: UIWindow?
  private var controller: VibeNativeCallOverlayController?

  private init() {}

  func startObserving() {
    guard observer == nil else { return }
    observer = NotificationCenter.default.addObserver(
      forName: VibeNativeCallEngine.stateDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self,
        let state = notification.userInfo?["state"] as? [String: Any]
      else { return }
      Task { @MainActor in
        self.applyEngineState(state)
      }
    }
  }

  func showOutgoing(payload: [String: Any], status: [String: Any]) {
    startObserving()
    var state = status
    for key in [
      "event", "callId", "callType", "toUserId", "toUserName", "toUserImage", "chatId",
      "signalingAccepted", "signalingQueued", "failureReason",
    ] where state[key] == nil {
      state[key] = payload[key]
    }
    if state["direction"] == nil {
      state["direction"] = "outgoing"
    }
    present(state: state, retryPayload: payload)
  }

  func refreshFromEngine() {
    startObserving()
    applyEngineState(VibeNativeCallEngine.shared.getStatus())
  }

  private func applyEngineState(_ state: [String: Any]) {
    let stateValue = normalizedString(state["state"]) ?? ""
    let direction = normalizedString(state["direction"]) ?? ""
    guard ["ringing", "starting", "connecting", "active", "failed", "ended"].contains(stateValue)
      || (stateValue == "configured" && controller != nil)
    else { return }

    if stateValue == "ended" {
      present(state: state, retryPayload: nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
        guard let self, self.controller?.callId == self.normalizedString(state["callId"] ?? state["call_id"])
        else { return }
        self.hide()
      }
      return
    }

    if direction == "incoming", stateValue == "ringing", UIApplication.shared.applicationState == .active {
      VibeNativeCallManager.shared.presentForegroundIncomingBanner(state)
      return
    }

    if controller == nil, direction == "incoming" || direction == "outgoing" || stateValue == "failed" {
      present(state: state, retryPayload: nil)
    } else {
      controller?.applyState(state, retryPayload: nil)
    }
  }

  private func present(state: [String: Any], retryPayload: [String: Any]?) {
    guard let scene = activeWindowScene() else {
      NSLog("[VibeNativeCall][Overlay] present skipped missing window scene")
      return
    }

    let controller = self.controller ?? VibeNativeCallOverlayController()
    controller.onDismiss = { [weak self] in self?.hide() }
    controller.applyState(state, retryPayload: retryPayload)

    if window == nil {
      let nextWindow = UIWindow(windowScene: scene)
      nextWindow.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 2)
      nextWindow.backgroundColor = .clear
      nextWindow.rootViewController = controller
      nextWindow.makeKeyAndVisible()
      window = nextWindow
      self.controller = controller
    } else if self.controller == nil {
      window?.rootViewController = controller
      self.controller = controller
      window?.isHidden = false
    } else {
      window?.isHidden = false
    }

    NSLog(
      "[VibeNativeCall][Overlay] present state=%@ direction=%@ callId=%@",
      normalizedString(state["state"]) ?? "-",
      normalizedString(state["direction"]) ?? "-",
      normalizedString(state["callId"] ?? state["call_id"]) ?? "-"
    )
  }

  private func hide() {
    controller?.cancelTimers()
    controller = nil
    window?.isHidden = true
    window = nil
  }

  private func activeWindowScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first(where: { $0.activationState == .foregroundActive })
      ?? scenes.first(where: { $0.activationState == .foregroundInactive })
      ?? scenes.first
  }

  private func normalizedString(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

@MainActor
private final class VibeNativeCallOverlayModel: ObservableObject {
  @Published var currentState: [String: Any] = [:]
  @Published var retryPayload: [String: Any]?
  @Published var inlineError: String?

  var onDismiss: (() -> Void)?
  private var timeoutWork: DispatchWorkItem?

  var callId: String? {
    normalizedString(currentState["callId"] ?? currentState["call_id"])
  }

  var displayName: String {
    normalizedString(currentState["toUserName"] ?? currentState["to_user_name"])
      ?? normalizedString(currentState["fromUserName"] ?? currentState["from_user_name"])
      ?? normalizedString(currentState["name"])
      ?? "Vibe Call"
  }

  var initial: String {
    displayName.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "V"
  }

  var directionTitle: String {
    let type = normalizedString(currentState["callType"] ?? currentState["call_type"]) == "video" ? "Video" : "Voice"
    switch normalizedString(currentState["direction"]) {
    case "incoming": return "Incoming \(type) Call"
    case "outgoing": return "Outgoing \(type) Call"
    default: return "\(type) Call"
    }
  }

  var statusText: String {
    if let inlineError { return inlineError }
    switch normalizedString(currentState["state"]) ?? "ringing" {
    case "ringing", "starting": return "Ringing..."
    case "connecting": return "Connecting..."
    case "active": return "Connected"
    case "failed": return friendlyFailureText
    case "ended": return "Call ended"
    default: return "Connecting..."
    }
  }

  var actionSet: VibeNativeCallOverlayActionSet {
    let stateValue = normalizedString(currentState["state"]) ?? "ringing"
    let direction = normalizedString(currentState["direction"]) ?? ""
    if stateValue == "failed" { return .failed }
    if direction == "incoming", stateValue == "ringing" { return .incoming }
    if stateValue == "ended" { return .ended }
    return .active
  }

  func applyState(_ state: [String: Any], retryPayload: [String: Any]?) {
    currentState = mergedState(existing: currentState, incoming: state)
    inlineError = nil
    if let retryPayload {
      self.retryPayload = retryPayload
    }
    if self.retryPayload == nil, normalizedString(currentState["direction"]) == "outgoing" {
      self.retryPayload = outgoingPayload(from: currentState)
    }
    scheduleTimeoutIfNeeded()
  }


  func cancelTimers() {
    timeoutWork?.cancel()
    timeoutWork = nil
  }

  func accept() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    applyState(VibeNativeCallEngine.shared.acceptIncoming(currentPayload()), retryPayload: nil)
  }

  func end() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    applyState(VibeNativeCallEngine.shared.endCall(currentPayload()), retryPayload: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
      self?.onDismiss?()
    }
  }

  func retry() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    guard var payload = retryPayload ?? outgoingPayload(from: currentState) else {
      inlineError = "Call could not start. Open the chat and try again."
      return
    }
    guard let config = AppSessionConfig.current else {
      inlineError = "Call could not start. Sign in again and retry."
      return
    }
    _ = VibeNativeCallEngine.shared.configure(config.payload)
    let now = Int(Date().timeIntervalSince1970 * 1000)
    payload["event"] = "call-start"
    payload["callId"] = "call_\(now)_\(UUID().uuidString.prefix(8))"
    payload["direction"] = "outbound"
    retryPayload = payload
    applyState(VibeNativeCallEngine.shared.startOutgoing(payload), retryPayload: payload)
  }

  func close() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    onDismiss?()
  }

  private var friendlyFailureText: String {
    if let reason = normalizedString(currentState["failureReason"]) {
      return reason
    }
    if boolValue(currentState["signalingQueued"]) {
      return "Still waiting for the connection. You can retry the call."
    }
    return "Call could not start. Check the connection and try again."
  }

  private func scheduleTimeoutIfNeeded() {
    timeoutWork?.cancel()
    timeoutWork = nil
    let stateValue = normalizedString(currentState["state"]) ?? ""
    let direction = normalizedString(currentState["direction"]) ?? ""
    guard direction == "outgoing", ["ringing", "starting"].contains(stateValue), let callId else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self,
        self.callId == callId,
        ["ringing", "starting"].contains(self.normalizedString(self.currentState["state"]) ?? "")
      else { return }
      self.applyState(
        VibeNativeCallEngine.shared.failCall(self.currentPayload(), reason: "No answer. You can retry the call."),
        retryPayload: self.retryPayload ?? self.outgoingPayload(from: self.currentState)
      )
    }
    timeoutWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: work)
  }

  private func currentPayload() -> [String: Any] {
    var payload = currentState
    if let callId {
      payload["callId"] = callId
    }
    if normalizedString(payload["toUserId"] ?? payload["to_user_id"]) == nil,
      let fromUserId = normalizedString(payload["fromUserId"] ?? payload["from_user_id"])
    {
      payload["toUserId"] = fromUserId
    }
    return payload
  }

  private func outgoingPayload(from state: [String: Any]) -> [String: Any]? {
    guard let toUserId = normalizedString(state["toUserId"] ?? state["to_user_id"]) else {
      return nil
    }
    return [
      "event": "call-start",
      "callType": normalizedString(state["callType"] ?? state["call_type"]) ?? "voice",
      "toUserId": toUserId,
      "toUserName": displayName,
      "toUserImage": normalizedString(state["toUserImage"] ?? state["to_user_image"]) ?? "",
      "chatId": normalizedString(state["chatId"] ?? state["chat_id"]) ?? "",
    ]
  }

  private func mergedState(existing: [String: Any], incoming: [String: Any]) -> [String: Any] {
    var next = existing
    for (key, value) in incoming where !(value is NSNull) {
      next[key] = value
    }
    return next
  }

  private func normalizedString(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func boolValue(_ value: Any?) -> Bool {
    switch value {
    case let bool as Bool: return bool
    case let number as NSNumber: return number.boolValue
    case let string as String:
      let raw = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return raw == "true" || raw == "1" || raw == "yes"
    default: return false
    }
  }
}

private enum VibeNativeCallOverlayActionSet {
  case incoming
  case active
  case failed
  case ended
}

private struct VibeNativeCallOverlayView: View {
  @ObservedObject var model: VibeNativeCallOverlayModel

  var body: some View {
    ZStack {
      Color.black.opacity(0.62).ignoresSafeArea()
      Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

      VStack(spacing: 0) {
        HStack {
          Spacer()
          if model.actionSet == .failed || model.actionSet == .ended {
            Button(action: model.close) {
              Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .tint(.white.opacity(0.78))
            .accessibilityLabel("Close")
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)

        Spacer()

        VStack(spacing: 12) {
          Text(model.initial)
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 104, height: 104)
            .background(.white.opacity(0.14), in: Circle())
            .padding(.bottom, 18)

          Text(model.directionTitle)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.68))

          Text(model.displayName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)

          Text(model.statusText)
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(0.78))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 28)
        }

        Spacer()

        VibeNativeCallOverlayActions(model: model)
          .padding(.bottom, 52)
      }
    }
  }
}

private struct VibeNativeCallOverlayActions: View {
  @ObservedObject var model: VibeNativeCallOverlayModel

  var body: some View {
    HStack(spacing: 28) {
      switch model.actionSet {
      case .incoming:
        action(title: "Decline", symbol: "phone.down.fill", tint: .red, action: model.end)
        action(title: "Accept", symbol: "phone.fill", tint: .green, action: model.accept)
      case .active:
        action(title: "End", symbol: "phone.down.fill", tint: .red, action: model.end)
      case .failed:
        action(title: "Close", symbol: "xmark", tint: .white.opacity(0.16), action: model.close)
        action(title: "Retry", symbol: "arrow.clockwise", tint: .green, action: model.retry)
      case .ended:
        EmptyView()
      }
    }
  }

  private func action(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
    VStack(spacing: 8) {
      Button(action: action) {
        Image(systemName: symbol)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 60, height: 60)
      }
      .buttonStyle(.borderedProminent)
      .tint(tint)
      .clipShape(Circle())
      .accessibilityLabel(title)

      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.82))
    }
  }
}

private final class VibeNativeCallOverlayController: UIHostingController<VibeNativeCallOverlayView> {
  private let model = VibeNativeCallOverlayModel()

  var onDismiss: (() -> Void)? {
    get { model.onDismiss }
    set { model.onDismiss = newValue }
  }

  var callId: String? { model.callId }

  init() {
    super.init(rootView: VibeNativeCallOverlayView(model: model))
    view.backgroundColor = .clear
  }

  @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func applyState(_ state: [String: Any], retryPayload: [String: Any]?) {
    model.applyState(state, retryPayload: retryPayload)
  }

  func cancelTimers() {
    model.cancelTimers()
  }
}

@MainActor
final class AppShellCoordinator: ObservableObject {
  // Per-tab SwiftUI navigation paths. Contacts / Calls / Settings stay pure
  // SwiftUI pages hosted in UIHostingControllers and keep their own in-page
  // navigation through these stacks. The chat conversation is NOT here: it is
  // pushed onto the root navigation controller that wraps the whole tab bar
  // (rootNavigationController), so opening a chat is a native push z-above any
  // tab with a stable, self-owned header.
  @Published var contactsPath: [AppRoute] = []
  @Published var callsPath: [AppRoute] = []
  @Published var settingsPath: [AppRoute] = []
  // Mirror of the active tab so SwiftUI pages that read it (the chat home's
  // search trigger, Settings) stay in sync with the UIKit tab bar.
  @Published var selectedTab: AppShellTab = .chats
  // Bumped to ask the chat home to present the contact-search sheet.
  @Published var chatSearchPresentationRequestID: Int = 0

  // UIKit handles, set by AppRootTabBarController / the root factory.
  weak var tabBarController: UITabBarController?
  // The navigation controller that *wraps the whole tab bar controller*. A chat
  // conversation is pushed here so it slides in z-above ALL four tabs
  // (Calls / Contacts / Home / Settings) — openable from any tab, never nested
  // inside the Chats tab.
  weak var rootNavigationController: UINavigationController?

  /// Select a tab in both our mirror and the UIKit tab bar.
  func selectTab(_ tab: AppShellTab) {
    if selectedTab != tab {
      selectedTab = tab
    }
    guard let index = AppRootTabBarController.tabIndex(for: tab),
      let tabBarController, tabBarController.selectedIndex != index
    else { return }
    tabBarController.selectedIndex = index
  }

  func openChat(_ route: ChatRoute) {
    appShellRouteLog(
      "openChat requested chatId=\(route.chatId) title=\(route.title) fromTab=\(selectedTab)")
    if route.isBuiltInAgentSurface {
      appShellRouteLog(
        "openChat redirecting legacy built-in agent chatId=\(route.chatId) to agent transport")
      openAgentConversation()
      return
    }
    guard let nav = rootNavigationController else {
      appShellRouteLog("openChat skipped: no root navigation controller")
      return
    }
    // Open the chat in place over whatever tab the user is on — no tab switch,
    // no nesting in Home.
    if let top = nav.topViewController as? ChatConversationController, top.chatId == route.chatId {
      appShellRouteLog("openChat ignored duplicate chatId=\(route.chatId)")
      return
    }
    let isDark = nav.traitCollection.userInterfaceStyle == .dark
    let controller = ChatConversationController(
      route: route,
      isDark: isDark,
      onClose: { [weak nav] in
        guard let nav, nav.viewControllers.count > 1 else { return }
        nav.popViewController(animated: true)
      }
    )
    // The conversation is full-screen above the tab bar controller, so it
    // covers the tab bar by z-order; no hidesBottomBarWhenPushed needed.
    nav.pushViewController(controller, animated: true)
  }

  /// Open the AI agent conversation surface, reusing the existing
  /// `ChatNativeAgentView` (which streams over the `agent:<userId>` socket) hosted
  /// in `ChatAgentConversationController` with the same chat composer.
  func openAgentConversation() {
    guard let nav = rootNavigationController else {
      appShellRouteLog("openAgentConversation skipped: no root navigation controller")
      return
    }
    if nav.topViewController is ChatAgentConversationController {
      appShellRouteLog("openAgentConversation ignored duplicate")
      return
    }
    let isDark = nav.traitCollection.userInterfaceStyle == .dark
    let controller = ChatAgentConversationController(
      isDark: isDark,
      onClose: { [weak nav] in
        guard let nav, nav.viewControllers.count > 1 else { return }
        nav.popViewController(animated: true)
      }
    )
    nav.pushViewController(controller, animated: true)
  }

  /// Pop back to the tab shell. Native back/swipe handle the common case; this
  /// supports programmatic closes.
  func closePresentedChat(requestID: Int? = nil) {
    guard let nav = rootNavigationController, nav.viewControllers.count > 1 else { return }
    nav.popToRootViewController(animated: true)
  }

  func openChatSearch() {
    print("AppShellCoordinator: openChatSearch requested")
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if self.selectedTab != .chats {
        print("AppShellCoordinator: switching tab to chats before search")
        self.selectTab(.chats)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          print("AppShellCoordinator: triggering chatSearchPresentationRequestID after delay")
          self.chatSearchPresentationRequestID &+= 1
        }
      } else {
        print("AppShellCoordinator: already on chats tab, triggering search immediately")
        self.chatSearchPresentationRequestID &+= 1
      }
    }
  }
}

@MainActor
private final class ChatsViewModel: ObservableObject {
  @Published var rows: [ChatHomeListRow] = []
  @Published var archivedRows: [ChatHomeListRow] = []
  @Published var isLoading = false
  @Published var isLoadingArchived = false
  @Published var isWaitingForNetwork = false
  @Published var errorMessage: String?
  @Published var hasLoaded = false
  @Published var hasLoadedArchived = false

  private var backgroundRefreshTask: Task<Void, Never>?
  private var agentConversationObserver: NSObjectProtocol?
  private var realtimeMessageObserver: NSObjectProtocol?
  private var realtimeRefreshTask: Task<Void, Never>?

  init() {
    agentConversationObserver = NotificationCenter.default.addObserver(
      forName: ChatNativeAgentView.conversationsDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.rows = ChatHomeService.rowsIncludingBuiltInAgent(self.rows)
      }
    }

    // A message arrived in one of this user's chats — from a peer OR mirrored from
    // the user's own other device (server emits `new_message` on the user topic,
    // ChatEngine turns it into this signal). Refresh the list in near-real-time so a
    // message sent on the phone shows on the laptop's chat list without a re-open.
    realtimeMessageObserver = NotificationCenter.default.addObserver(
      forName: ChatEngine.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      // Refresh for BOTH a peer / other-device ping ("remoteNewMessage") AND a message
      // inserted locally on THIS device ("chatMessageInserted"). Without the latter, a
      // message the user sends here never nudges the home list — most visibly the very
      // first message in a brand-new conversation, whose preview would otherwise stay
      // blank until some unrelated remote nudge arrived.
      let reason = note.userInfo?["reason"] as? String
      guard reason == "remoteNewMessage" || reason == "chatMessageInserted" else { return }
      self?.scheduleRealtimeRefresh()
    }
  }

  deinit {
    backgroundRefreshTask?.cancel()
    realtimeRefreshTask?.cancel()
    if let agentConversationObserver {
      NotificationCenter.default.removeObserver(agentConversationObserver)
    }
    if let realtimeMessageObserver {
      NotificationCenter.default.removeObserver(realtimeMessageObserver)
    }
  }

  /// Debounce a light, row-preserving refresh so bursts of incoming messages (group
  /// traffic) coalesce into one fetch instead of a storm. No spinner — the list just
  /// updates its previews/unread in place.
  private func scheduleRealtimeRefresh() {
    guard hasLoaded else { return }
    realtimeRefreshTask?.cancel()
    realtimeRefreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 400_000_000)
      guard !Task.isCancelled, let self else { return }
      await self.refresh(preserveRows: true)
    }
  }

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    AppUITrace.notice("ChatsViewModel loadIfNeeded start rows=\(rows.count)")
    guard let config = AppSessionConfig.current else {
      if rows.isEmpty {
        errorMessage = "The current session is unavailable."
      }
      AppUITrace.error("ChatsViewModel loadIfNeeded missingSession rows=\(rows.count)")
      return
    }

    let cachedRows = ChatHomeService.cachedRows(config: config)
    if !cachedRows.isEmpty {
      rows = cachedRows
      hasLoaded = true
      isLoading = false
      isWaitingForNetwork = false
      errorMessage = nil
      warmCachedRows(cachedRows, shouldFetchHistory: false)
      scheduleArchivedLoadIfNeeded()
      AppUITrace.notice(
        "ChatsViewModel restored-cache rows=\(cachedRows.count) schedulingBackgroundRefresh=Y"
      )
      scheduleBackgroundRefreshAfterCachedStart()
      return
    }

    await refresh(preserveRows: false)
  }

  func refresh() async {
    backgroundRefreshTask?.cancel()
    backgroundRefreshTask = nil
    await refresh(preserveRows: false)
  }

  func loadArchivedIfNeeded() async {
    guard !hasLoadedArchived else { return }
    await refreshArchived(preserveRows: true)
  }

  func refreshArchived() async {
    await refreshArchived(preserveRows: false)
  }

  func refreshAll() async {
    await refresh(preserveRows: false)
    await refreshArchived(preserveRows: false)
  }

  private func refresh(preserveRows: Bool) async {
    let startedAt = ProcessInfo.processInfo.systemUptime
    AppUITrace.notice(
      "ChatsViewModel refresh start preserveRows=\(preserveRows ? "Y" : "N") currentRows=\(rows.count)"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatsViewModel refresh preserveRows=\(preserveRows ? "Y" : "N") rows=\(rows.count)"
    )
    guard let config = AppSessionConfig.current else {
      if rows.isEmpty {
        errorMessage = "The current session is unavailable."
      }
      AppUITrace.error("ChatsViewModel refresh missingSession rows=\(rows.count)")
      return
    }

    isLoading = rows.isEmpty && !preserveRows
    isWaitingForNetwork = false
    errorMessage = nil
    defer { isLoading = false }

    do {
      let nextRows = try await ChatHomeService.fetchChats(config: config)
      if Self.rowsSnapshotSignature(nextRows) != Self.rowsSnapshotSignature(rows) {
        rows = nextRows
        AppUITrace.notice(
          "ChatsViewModel refresh applied rows=\(nextRows.count) preserveRows=\(preserveRows ? "Y" : "N") durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))"
        )
      } else {
        AppUITrace.notice(
          "ChatsViewModel refresh skipped-identical rows=\(nextRows.count) preserveRows=\(preserveRows ? "Y" : "N") durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))"
        )
      }
      hasLoaded = true
      isWaitingForNetwork = false
      warmCachedRows(nextRows, shouldFetchHistory: true)
      scheduleArchivedLoadIfNeeded()
    } catch {
      let offline = ChatHomeService.isOfflineError(error)
      isWaitingForNetwork = offline
      if rows.isEmpty {
        errorMessage = error.localizedDescription
      } else {
        errorMessage = nil
      }
      hasLoaded = true
      AppUITrace.error(
        "ChatsViewModel refresh error offline=\(offline ? "Y" : "N") rows=\(rows.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)) error=\(error.localizedDescription)"
      )
    }
  }

  private func scheduleArchivedLoadIfNeeded() {
    guard !hasLoadedArchived else { return }
    Task { @MainActor [weak self] in
      await self?.loadArchivedIfNeeded()
    }
  }

  private func refreshArchived(preserveRows: Bool) async {
    guard let config = AppSessionConfig.current else { return }
    isLoadingArchived = archivedRows.isEmpty && !preserveRows
    defer { isLoadingArchived = false }

    do {
      let nextRows = try await ChatHomeService.fetchArchivedChats(config: config)
      if Self.rowsSnapshotSignature(nextRows) != Self.rowsSnapshotSignature(archivedRows) {
        archivedRows = nextRows
      }
      hasLoadedArchived = true
    } catch {
      hasLoadedArchived = true
      AppUITrace.error("ChatsViewModel archived refresh error \(error.localizedDescription)")
    }
  }

  private func scheduleBackgroundRefreshAfterCachedStart() {
    backgroundRefreshTask?.cancel()
    AppUITrace.notice("ChatsViewModel scheduleBackgroundRefreshAfterCachedStart")
    backgroundRefreshTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 450_000_000)
      } catch {
        return
      }
      await self?.refresh(preserveRows: true)
    }
  }

  private func warmCachedRows(_ rows: [ChatHomeListRow], shouldFetchHistory: Bool) {
    let visibleRows = Array(rows.prefix(4))
    for row in visibleRows
    where !row.isBuiltInAgentSurface && !row.isBridgeAgentSurface && !row.initialMessages.isEmpty {
      ChatEngine.shared.seedRecentChatHistory(
        chatId: row.chatId,
        messages: row.initialMessages,
        limit: 3
      )
    }

    guard shouldFetchHistory else { return }
    let preloadChatIds =
      visibleRows
      .filter { !$0.isBuiltInAgentSurface && !$0.isBridgeAgentSurface }
      .prefix(2)
      .map(\.chatId)
    AppUITrace.notice(
      "ChatsViewModel warmCachedRows rows=\(rows.count) preload=\(preloadChatIds.map { String($0.prefix(12)) }.joined(separator: ","))"
    )
    ChatEngine.shared.prefetchChatHistories(chatIds: preloadChatIds)
  }

  private static func rowsSnapshotSignature(_ rows: [ChatHomeListRow]) -> String {
    rows.map { row in
      [
        row.chatId,
        row.title,
        row.preview,
        row.timeLabel,
        "\(row.unreadCount)",
        "\(row.markedUnread)",
        "\(row.muted)",
        "\(row.pinned)",
        "\(row.archived)",
        "\(row.isTyping)",
        "\(row.isOnline)",
        row.avatarUri ?? "",
        row.peerTier ?? "",
      ].joined(separator: "\u{1F}")
    }.joined(separator: "\u{1E}")
  }
}

@MainActor
final class ContactDirectoryViewModel: ObservableObject {
  @Published var rows: [ChatHomeListRow] = []
  @Published var isLoading = false
  @Published var errorMessage: String?

  private var hasLoaded = false

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    await refresh()
  }

  func refresh() async {
    guard let config = AppSessionConfig.current else {
      rows = []
      errorMessage = "The current session is unavailable."
      return
    }

    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let chats = try await ChatHomeService.fetchChats(config: config)
      rows = chats.filter { row in
        !row.isSavedMessages && !row.isGroup && row.peerUserId != nil
      }
      hasLoaded = true
    } catch {
      rows = []
      errorMessage = error.localizedDescription
    }
  }
}

private struct ContactsRootView: View {
  @EnvironmentObject private var coordinator: AppShellCoordinator
  var body: some View {
    NavigationStack(path: $coordinator.contactsPath) {
      ContactsPageView()
    }
    .onAppear { appShellRouteLog("ContactsRootView onAppear") }
    .onDisappear { appShellRouteLog("ContactsRootView onDisappear") }
  }
}



private struct CallsRootView: View {
  @EnvironmentObject private var coordinator: AppShellCoordinator
  var body: some View {
    NavigationStack(path: $coordinator.callsPath) {
      CallsPageView()
    }
    .onAppear { appShellRouteLog("CallsRootView onAppear") }
    .onDisappear { appShellRouteLog("CallsRootView onDisappear") }
  }
}

private struct ChatHomeScreen: View {
  @EnvironmentObject private var coordinator: AppShellCoordinator
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model = ChatsViewModel()
  @State private var isShowingSearch = false
  @State private var isShowingStoryCamera = false
  @State private var isEditingHome = false
  @State private var isShowingArchivedChats = false
  @State private var selectedChatIDs = Set<String>()
  @State private var isStartingChat = false
  @State private var errorMessage: String?
  @State private var isShowingChannelCreation = false
  @State private var roomCreationName = ""
  @State private var isShowingGroupCreation = false
  @State private var homeSearchQuery = ""
  @State private var isHomeSearchFocused = false
  @State private var locallyHiddenChatIDs = Set<String>()
  @State private var pendingDeleteConfirmation: ChatHomeDeleteConfirmation?
  @State private var pendingDeletion: ChatHomePendingDeletion?
  @State private var pendingDeletionTask: Task<Void, Never>?
  /// Global username/phone/ID lookups (incl. Claude/Codex) for the search drawer.
  @State private var globalResults: [ContactSearchUser] = []
  @State private var isGlobalSearching = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var filteredRows: [ChatHomeListRow] {
    let query = homeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return homeRowsWithArchiveEntry }
    return visibleHomeRows.filter { row in
      row.title.localizedCaseInsensitiveContains(query)
        || row.preview.localizedCaseInsensitiveContains(query)
    }
  }

  private var visibleHomeRows: [ChatHomeListRow] {
    model.rows.filter { !locallyHiddenChatIDs.contains($0.chatId) }
  }

  private var visibleArchivedRows: [ChatHomeListRow] {
    model.archivedRows.filter { !locallyHiddenChatIDs.contains($0.chatId) }
  }

  private var homeRowsWithArchiveEntry: [ChatHomeListRow] {
    guard !visibleArchivedRows.isEmpty else { return visibleHomeRows }
    let archiveRow = Self.archiveEntryRow(count: visibleArchivedRows.count)
    var rows = visibleHomeRows.filter { !$0.isArchiveEntry }
    let insertionIndex = rows.first?.isSavedMessages == true ? 1 : 0
    rows.insert(archiveRow, at: insertionIndex)
    return rows
  }

  private var hasHomeRowsForAnyScope: Bool {
    !visibleHomeRows.isEmpty || !visibleArchivedRows.isEmpty
  }

  private var trimmedHomeQuery: String {
    homeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func archiveEntryRow(count: Int) -> ChatHomeListRow {
    ChatHomeListRow(
      chatId: "archive",
      title: "Archived",
      preview: count == 1 ? "1 archived chat" : "\(count) archived chats",
      timeLabel: "",
      unreadCount: 0,
      markedUnread: false,
      muted: false,
      pinned: false,
      archived: false,
      isTyping: false,
      isOnline: false,
      peerUserId: nil,
      avatarUri: nil,
      avatarFallback: "A",
      avatarGradientStartLight: nil,
      avatarGradientEndLight: nil,
      avatarGradientStartDark: nil,
      avatarGradientEndDark: nil,
      isSavedMessages: false,
      isArchiveEntry: true,
      type: "archive_entry",
      isGroup: false,
      isAgentFriend: false,
      peerAgentId: nil,
      agentEventInboxMode: nil,
      peerTier: nil,
      previewRows: [],
      initialMessages: []
    )
  }

  /// Claude/Codex surfaced instantly on a username prefix (no network). They are
  /// real users but the exact-match `/user/name/:username` lookup only hits on the
  /// full handle, so we offer them as soon as the user starts typing "cl"/"co".
  private func agentSuggestions(for query: String) -> [ContactSearchUser] {
    let q = query.lowercased()
    guard !q.isEmpty else { return [] }
    let agents = [
      (ChatRoute.claudeAgentUserId, "claude"),
      (ChatRoute.codexAgentUserId, "codex"),
    ]
    return agents.compactMap { uid, uname in
      guard uname.hasPrefix(q) else { return nil }
      return ContactSearchUser(payload: ["userId": uid, "username": uname, "isAgent": true])
    }
  }

  /// People to show in the search drawer: agent suggestions + global lookups,
  /// de-duplicated and minus anyone already listed under "Chats".
  private var combinedPeopleResults: [ContactSearchUser] {
    var seen = Set<String>()
    var out: [ContactSearchUser] = []
    for user in agentSuggestions(for: trimmedHomeQuery) + globalResults {
      if seen.insert(user.userID.uppercased()).inserted { out.append(user) }
    }
    let existingPeerIds = Set(filteredRows.compactMap { $0.peerUserId?.uppercased() })
    return out.filter { !existingPeerIds.contains($0.userID.uppercased()) }
  }

  @MainActor
  private func runGlobalSearch() async {
    let q = trimmedHomeQuery
    guard q.count >= 2 else {
      globalResults = []
      return
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    if Task.isCancelled { return }
    guard let config = AppSessionConfig.current else { return }
    isGlobalSearching = true
    defer { isGlobalSearching = false }
    let found = (try? await ContactSearchService.search(config: config, query: q)) ?? []
    if Task.isCancelled { return }
    globalResults = found
  }

  private func openLocalChatRow(_ row: ChatHomeListRow) {
    if !row.isBuiltInAgentSurface, !row.isBridgeAgentSurface, !row.initialMessages.isEmpty {
      ChatEngine.shared.seedRecentChatHistory(
        chatId: row.chatId, messages: row.initialMessages, limit: 3)
    }
    coordinator.openChat(ChatRoute(row: row))
  }

  private func handleGlobalUserTap(_ user: ContactSearchUser) {
    isHomeSearchFocused = false
    Task { _ = await openChat(for: user) }
  }

  var body: some View {
    NavigationStack {
      ZStack {
        listContent
          .ignoresSafeArea(.container, edges: .top)
          .background(palette.background.ignoresSafeArea())

        if let pendingDeletion {
          VStack {
            Spacer()
            ChatHomeDeletionUndoToast(
              deletion: pendingDeletion,
              palette: palette,
              undo: undoPendingHomeDelete
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 0)
            .transition(.scale(scale: 0.94).combined(with: .opacity).animation(.easeOut(duration: 0.25)))
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .allowsHitTesting(true)
        }

        if let confirmation = pendingDeleteConfirmation {
          ChatHomeDeleteDialogView(
            confirmation: confirmation,
            palette: palette,
            deleteForMe: {
              beginPendingHomeDelete(row: confirmation.row, deleteForEveryone: false)
            },
            deleteForEveryone: confirmation.allowsDeleteForEveryone
              ? {
                beginPendingHomeDelete(row: confirmation.row, deleteForEveryone: true)
              } : nil,
            cancel: {
              pendingDeleteConfirmation = nil
            }
          )
          .transition(.opacity.combined(with: .scale(scale: 0.98)))
          .zIndex(3)
        }
      }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: pendingDeletion?.id)
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: pendingDeleteConfirmation?.id)
        .navigationBarTitleDisplayMode(.inline)
        // Let iOS 26 apply its native adaptive Liquid Glass to the nav bar and
        // toolbar items. An explicit .toolbarBackground / .sharedBackgroundVisibility(.hidden)
        // suppressed that glass, which is what the user saw as "removed glass".
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button(isEditingHome ? "Done" : "Edit") {
              withAnimation { isEditingHome.toggle() }
              if !isEditingHome {
                selectedChatIDs.removeAll()
              }
            }
            .font(.system(size: 17, weight: .semibold))
            .tint(
              filteredRows.isEmpty
                ? (colorScheme == .dark ? Color.white.opacity(0.3) : Color.black.opacity(0.3))
                : (colorScheme == .dark ? .white : .black)
            )
            .disabled(filteredRows.isEmpty)
          }

          ToolbarItem(placement: .principal) {
            AppHomeStatusHeaderView(
              state: model.isWaitingForNetwork ? .waitingForNetwork : .ready,
              palette: palette
            )
          }

          if !isEditingHome {
            ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 18) {
              Button {
                openAgentChat()
              } label: {
                Image("BrandLogo")
                  .renderingMode(.template)
                  .resizable()
                  .scaledToFit()
                  .foregroundStyle(colorScheme == .dark ? .white : .black)
                  .frame(width: 22, height: 22)
              }
              .buttonStyle(.plain)
              .contentShape(Rectangle())

              Button {
                isShowingStoryCamera = true
              } label: {
                AppVectorIcon(glyph: .story, tint: colorScheme == .dark ? .white : .black)
                  .frame(width: 22, height: 22)
              }
              .buttonStyle(.plain)
              .contentShape(Rectangle())

              Button {
                isShowingSearch = true
              } label: {
                AppVectorIcon(glyph: .compose, tint: colorScheme == .dark ? .white : .black)
                  .frame(width: 22, height: 22)
              }
              .buttonStyle(.plain)
              .contentShape(Rectangle())
            }
            .padding(.horizontal, 6)
          }
          }
        }
        .searchable(
          text: $homeSearchQuery,
          isPresented: $isHomeSearchFocused,
          placement: .navigationBarDrawer(displayMode: .automatic),
          prompt: "Search Chats"
        )
        .onChange(of: isHomeSearchFocused) { _, isPresented in
          if !isPresented {
            homeSearchQuery = ""
          }
        }
        .navigationDestination(isPresented: $isShowingArchivedChats) {
          ArchivedChatHomeListScreen(
            model: model,
            palette: palette,
            isDark: colorScheme == .dark,
            hiddenChatIDs: locallyHiddenChatIDs,
            openRow: openLocalChatRow,
            performAction: performHomeRowAction
          )
        }
    }
    .task {
      AppUITrace.notice("ChatHomeScreen task loadIfNeeded")
      await model.loadIfNeeded()
      await model.loadArchivedIfNeeded()
    }
    .task(id: homeSearchQuery) {
      await runGlobalSearch()
    }
    .onAppear {
      AppUITrace.notice(
        "ChatHomeScreen onAppear rows=\(model.rows.count) searchRequest=\(coordinator.chatSearchPresentationRequestID)"
      )
      AppUIStallWatchdog.shared.updateContext("ChatHomeScreen appear rows=\(model.rows.count)")
      // We no longer present the modal on appear, as we now use search focus
    }
    .onChange(of: coordinator.chatSearchPresentationRequestID) { _, _ in
      AppUITrace.notice(
        "ChatHomeScreen searchRequest changed requestId=\(coordinator.chatSearchPresentationRequestID) selectedTab=\(coordinator.selectedTab)"
      )
      isHomeSearchFocused = true
    }
    .sheet(isPresented: $isShowingSearch) {
      if let config = AppSessionConfig.current {
        NavigationStack {
          ContactSearchView(config: config, homeRows: visibleHomeRows) { payload in
            handleSearchPayload(payload)
          }
        }
      }
    }
    .sheet(isPresented: $isShowingGroupCreation) {
      if let config = AppSessionConfig.current {
        ChatGroupCreationSheet(config: config, homeRows: visibleHomeRows) { route in
          coordinator.openChat(route)
          Task { await model.refresh() }
        }
      }
    }
    .sheet(isPresented: $isShowingChannelCreation) {
      if let config = AppSessionConfig.current {
        ChannelCreationSheet(config: config) { route in
          coordinator.openChat(route)
          Task { await model.refresh() }
        }
      }
    }
    .fullScreenCover(isPresented: $isShowingStoryCamera) {
      AppNativeStoryCameraPage {
        AppUITrace.notice("ChatHomeScreen story close")
        isShowingStoryCamera = false
      }
      .ignoresSafeArea()
    }
  }


  @ViewBuilder
  private var listContent: some View {
    if !trimmedHomeQuery.isEmpty {
      searchResultsView
    } else if !hasHomeRowsForAnyScope && (!model.hasLoaded || model.isLoading) {
      ProgressView()
        .controlSize(.regular)
        .tint(palette.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
    } else if !hasHomeRowsForAnyScope {
      AppShellEmptyStateView(
        icon: """
        <?xml version="1.0" encoding="utf-8"?><svg fill="none" viewBox="0 0 800 600" xmlns="http://www.w3.org/2000/svg"><defs><clipPath id="cp-800-600"><rect height="600" width="800" y="0" x="0" /></clipPath><g id="comp_0"><g opacity="0" id="planete Outlines - Group 5"><animate repeatCount="indefinite" attributeName="opacity" dur="3s" begin="0s" calcMode="spline" values="0; 1; 1; 0" keyTimes="0; 0.3; 0.68; 1" keySplines="0.333 0 0.667 1; 0.333 0 0.667 1; 0.333 0 0.667 1" fill="freeze" /><g transform="translate(327.38,267.583)"><animateTransform repeatCount="indefinite" type="translate" attributeName="transform" dur="3s" begin="0s" calcMode="spline" values="327.38 267.583; 482.38 267.583" keyTimes="0; 1" keySplines="0 0 1 1" fill="freeze" /><g transform="scale(0.5,0.5) translate(-171.76,-193.166)"><g id="Group 5" transform="matrix(1,0,0,1,171.76,193.166)"><path fill="#d0d2d3" fill-opacity="1" d="M59.669,-8.242C53.143,-8.242,47.22,-5.677,42.84,-1.506C42.047,-23.225,24.2,-40.592,2.287,-40.592C-17.519,-40.592,-34.001,-26.403,-37.576,-7.638C-39.31,-8.029,-41.111,-8.242,-42.962,-8.242C-56.447,-8.242,-67.378,2.69,-67.378,16.174C-67.378,16.467,-67.367,16.758,-67.356,17.049C-68.756,16.49,-70.279,16.174,-71.878,16.174C-78.62,16.174,-84.086,21.64,-84.086,28.383C-84.086,35.125,-78.62,40.591,-71.878,40.591L59.669,40.591C73.154,40.591,84.086,29.659,84.086,16.174C84.086,2.69,73.154,-8.242,59.669,-8.242Z" /></g></g></g></g><g id="Merged Shape Layer"><g transform="translate(390.319,298.2)"><animateTransform repeatCount="indefinite" type="translate" attributeName="transform" dur="3s" begin="0s" calcMode="spline" values="390.319 298.2; 390.319 282.7; 390.319 319.25; 390.319 298.2" keyTimes="0; 0.293; 0.733; 1" keySplines="0.333 0 0.667 1; 0.333 0 0.667 1; 0.333 0 0.667 1" fill="freeze" /><g transform="rotate(0)"><animateTransform repeatCount="indefinite" type="rotate" attributeName="transform" dur="3s" begin="0s" calcMode="spline" values="0; 35; 0" keyTimes="0; 0.513; 1" keySplines="0.547 0 0.667 1; 0.333 0 0.845 1" fill="freeze" /><g transform="scale(1,1) translate(-664.319,-256.2)"><g id="planete Outlines - Group 3" transform="matrix(0.5,0,0,0.5,515.5,129)"><g id="Group 3" transform="matrix(1,0,0,1,297.638,254.4)"><path fill="#5d68f9" fill-opacity="1" d="M-133.812,-42.171L133.812,-75.141L5.765,75.141L-61.708,18.402L124.227,-71.307L-87.011,-1.534L-133.812,-42.171Z" /></g></g><g id="planete Outlines - Group 2" transform="matrix(0.5,0,0,0.5,515.5,129)"><g id="Group 2" transform="matrix(1,0,0,1,316.247,247.882)"><path fill="#474bd8" fill-opacity="1" d="M-98.335,64.79L-105.619,4.984L105.619,-64.79L-80.316,24.919L-98.335,64.79Z" /></g></g><g id="planete Outlines - Group 1" transform="matrix(0.5,0,0,0.5,515.5,129.001)"><g id="Group 1" transform="matrix(1,0,0,1,236.879,292.737)"><path fill="#3931ac" fill-opacity="1" d="M18.967,-3.189L-18.967,19.935L-0.949,-19.935L18.967,-3.189Z" /></g></g></g></g></g></g><g opacity="0" id="planete Outlines - Group 4"><animate repeatCount="indefinite" attributeName="opacity" dur="2.4s" begin="0s" calcMode="spline" values="0; 0.5; 0.5; 0" keyTimes="0; 0.317; 0.733; 1" keySplines="0 0 1 1; 0 0 1 1; 0 0 1 1" fill="freeze" /><g transform="translate(468.336,323.378)"><animateTransform repeatCount="indefinite" type="translate" attributeName="transform" dur="2.04s" begin="0s" calcMode="spline" values="468.336 323.378; 294.336 323.378" keyTimes="0; 1" keySplines="0 0 1 1" fill="freeze" /><g transform="scale(0.5,0.5) translate(-453.672,-304.756)"><g id="Group 4" transform="matrix(1,0,0,1,453.672,304.756)"><path fill="#d0d2d3" fill-opacity="1" d="M75.134,16.175C74.353,16.175,73.591,16.256,72.85,16.396C72.851,16.322,72.856,16.249,72.856,16.175C72.856,2.691,61.924,-8.241,48.44,-8.241C46.662,-8.241,44.931,-8.046,43.262,-7.685C39.668,-26.427,23.196,-40.591,3.406,-40.591C-16.624,-40.591,-33.254,-26.077,-36.571,-6.995C-38.992,-7.799,-41.578,-8.241,-44.269,-8.241C-57.754,-8.241,-68.685,2.691,-68.685,16.175C-68.685,16.817,-68.652,17.45,-68.604,18.079C-70.494,16.88,-72.728,16.175,-75.133,16.175C-81.875,16.175,-87.341,21.641,-87.341,28.383C-87.341,35.126,-81.875,40.592,-75.133,40.592L75.134,40.592C81.876,40.592,87.342,35.126,87.342,28.383C87.342,21.641,81.876,16.175,75.134,16.175Z" /></g></g></g></g></g></defs><g transform="matrix(1.79,0,0,1.79,-310,-231)" id="Pre-comp 1"><use clip-path="url(#cp-800-600)" height="600" width="800" y="0" x="0" xlink:href="#comp_0" href="#comp_0" /></g></svg>
        """,
        title: model.isWaitingForNetwork ? "Waiting for Network" : "No Messages Yet",
        message: errorMessage ?? model.errorMessage
          ?? (model.isWaitingForNetwork
            ? "Your chats will stay here when the connection returns."
            : "Start a conversation to catch the vibe."),
        buttonTitle: "New Chat",
        palette: palette
      ) {
        isShowingSearch = true
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(palette.background)
    } else {
      ChatHomeNativeListRepresentable(
        rows: filteredRows,
        isDark: colorScheme == .dark,
        isEditing: isEditingHome,
        showsRightCheckmark: false,
        selectedChatIDs: selectedChatIDs,
        onSelect: { row in
          if row.isArchiveEntry {
            selectedChatIDs.removeAll()
            isShowingArchivedChats = true
            Task { await model.loadArchivedIfNeeded() }
            return
          }
          AppUITrace.notice(
            "ChatHomeScreen select chatId=\(String(row.chatId.prefix(12))) title=\(row.title) rows=\(model.rows.count) initialMessages=\(row.initialMessages.count)"
          )
          AppUIStallWatchdog.shared.updateContext(
            "ChatHomeScreen select chatId=\(String(row.chatId.prefix(12))) rows=\(model.rows.count)"
          )
          if !row.isBuiltInAgentSurface, !row.isBridgeAgentSurface, !row.initialMessages.isEmpty {
            ChatEngine.shared.seedRecentChatHistory(
              chatId: row.chatId,
              messages: row.initialMessages,
              limit: 3
            )
          }
          coordinator.openChat(ChatRoute(row: row))
        },
        onToggleSelection: { chatID in
          toggleHomeSelection(chatID)
        },
        onAction: { action, row in
          performHomeRowAction(action, row: row)
        },
        onRefresh: {
          await model.refreshAll()
        },
        onUnavailableAction: { AppToastController.shared.show($0) }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }


  @ViewBuilder
  private var searchResultsView: some View {
    let chats = filteredRows
    let people = combinedPeopleResults
    if chats.isEmpty && people.isEmpty {
      ContactSearchStatusView(
        isLoading: isGlobalSearching,
        hasSearched: !isGlobalSearching,
        message: isGlobalSearching ? "" : "No chats or people match \"\(trimmedHomeQuery)\".",
        palette: palette
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(palette.background)
    } else {
      List {
        if !chats.isEmpty {
          Section(header: Text("Chats").foregroundStyle(palette.secondaryText)) {
            ForEach(chats, id: \.chatId) { row in
              Button { openLocalChatRow(row) } label: {
                HomeSearchChatRow(row: row, palette: palette)
              }
              .buttonStyle(.plain)
              .listRowBackground(palette.background)
            }
          }
        }
        if !people.isEmpty {
          Section(header: Text("People").foregroundStyle(palette.secondaryText)) {
            ForEach(people) { user in
              Button { handleGlobalUserTap(user) } label: {
                ContactSearchResultRow(user: user, isSaved: false, palette: palette)
              }
              .buttonStyle(.plain)
              .listRowBackground(palette.background)
            }
          }
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(palette.background)
    }
  }

  private func toggleHomeSelection(_ chatID: String) {
    AppUITrace.notice(
      "ChatsRootView toggleSelection chatId=\(String(chatID.prefix(12))) selectedBefore=\(selectedChatIDs.count)"
    )
    if selectedChatIDs.contains(chatID) {
      selectedChatIDs.remove(chatID)
    } else {
      selectedChatIDs.insert(chatID)
    }
  }

  /// Open the "talk to the agent" surface from the header sparkles button. Reuses
  /// the existing native agent view (`ChatNativeAgentView`) which already streams
  /// over the `agent:<userId>` socket, hosted with the same `ChatInputBar`
  /// composer the chat uses.
  private func openAgentChat() {
    AppUITrace.notice("ChatHomeScreen openAgentChat: opening native agent conversation")
    coordinator.openAgentConversation()
  }

  @MainActor
  private func performHomeEditAction(_ action: ChatHomeEditBulkAction) async {
    guard !selectedChatIDs.isEmpty else { return }
    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("The current session is unavailable.")
      return
    }

    let chatIDs = Array(selectedChatIDs)
    AppUITrace.notice(
      "ChatsRootView bulkAction start action=\(action) selected=\(chatIDs.count)"
    )
    do {
      try await ChatHomeEditService.apply(action: action, chatIDs: chatIDs, config: config)
      selectedChatIDs.removeAll()
      isEditingHome = false
      await model.refresh()
      AppUITrace.notice("ChatsRootView bulkAction done action=\(action)")
    } catch {
      AppUITrace.error("ChatsRootView bulkAction error action=\(action) error=\(error.localizedDescription)")
      AppToastController.shared.show(error.localizedDescription)
    }
  }

  private func performHomeRowAction(_ action: ChatHomeRowAction, row: ChatHomeListRow) {
    guard row.supportsRemoteHomeActions else {
      AppToastController.shared.show("This chat is stored locally and cannot use server actions.")
      return
    }

    if action == .delete {
      requestHomeDelete(row: row)
      return
    }

    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("The current session is unavailable.")
      return
    }

    Task { @MainActor in
      do {
        try await ChatHomeEditService.apply(action: action, chatID: row.chatId, config: config)
        selectedChatIDs.remove(row.chatId)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        await model.refreshAll()
      } catch {
        AppUITrace.error(
          "ChatHomeScreen rowAction error chatId=\(String(row.chatId.prefix(12))) error=\(error.localizedDescription)"
        )
        AppToastController.shared.show(error.localizedDescription)
      }
    }
  }

  private func requestHomeDelete(row: ChatHomeListRow) {
    openPendingSwipeIfNeeded()
    pendingDeleteConfirmation = ChatHomeDeleteConfirmation(row: row)
  }

  private func openPendingSwipeIfNeeded() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
  }

  private func beginPendingHomeDelete(row: ChatHomeListRow, deleteForEveryone: Bool) {
    if let previous = pendingDeletion {
      pendingDeletionTask?.cancel()
      Task { @MainActor in
        await commitHomeDelete(previous)
      }
    }

    pendingDeleteConfirmation = nil
    locallyHiddenChatIDs.insert(row.chatId)
    selectedChatIDs.remove(row.chatId)
    let deletion = ChatHomePendingDeletion(
      row: row,
      deleteForEveryone: deleteForEveryone,
      duration: 5
    )
    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
      pendingDeletion = deletion
    }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    _ = ChatEngine.shared.clearChat([
      "chatId": row.chatId,
      "localOnly": true,
    ])

    pendingDeletionTask?.cancel()
    pendingDeletionTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(deletion.duration * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await commitHomeDelete(deletion)
    }
  }

  private func undoPendingHomeDelete() {
    guard let deletion = pendingDeletion else { return }
    pendingDeletionTask?.cancel()
    pendingDeletionTask = nil
    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
      pendingDeletion = nil
    }
    locallyHiddenChatIDs.remove(deletion.row.chatId)
    if !deletion.row.initialMessages.isEmpty {
      ChatEngine.shared.seedRecentChatHistory(
        chatId: deletion.row.chatId,
        messages: deletion.row.initialMessages,
        limit: 5
      )
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  @MainActor
  private func commitHomeDelete(_ deletion: ChatHomePendingDeletion) async {
    guard let config = AppSessionConfig.current else {
      restoreFailedHomeDelete(deletion, message: "The current session is unavailable.")
      return
    }

    do {
      try await ChatHomeEditService.deleteChat(
        chatID: deletion.row.chatId,
        config: config,
        deleteForEveryone: deletion.deleteForEveryone
      )
      if pendingDeletion?.id == deletion.id {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
          pendingDeletion = nil
        }
        pendingDeletionTask = nil
      }
      selectedChatIDs.remove(deletion.row.chatId)
      await model.refreshAll()
      AppUITrace.notice(
        "ChatHomeScreen delete committed chatId=\(String(deletion.row.chatId.prefix(12))) forEveryone=\(deletion.deleteForEveryone ? "Y" : "N")"
      )
    } catch {
      restoreFailedHomeDelete(deletion, message: error.localizedDescription)
      AppUITrace.error(
        "ChatHomeScreen delete failed chatId=\(String(deletion.row.chatId.prefix(12))) error=\(error.localizedDescription)"
      )
    }
  }

  private func restoreFailedHomeDelete(_ deletion: ChatHomePendingDeletion, message: String) {
    if pendingDeletion?.id == deletion.id {
      withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
        pendingDeletion = nil
      }
      pendingDeletionTask = nil
    }
    locallyHiddenChatIDs.remove(deletion.row.chatId)
    if !deletion.row.initialMessages.isEmpty {
      ChatEngine.shared.seedRecentChatHistory(
        chatId: deletion.row.chatId,
        messages: deletion.row.initialMessages,
        limit: 5
      )
    }
    AppToastController.shared.show(message)
  }

  private func handleSearchPayload(_ payload: [String: Any]) {
    guard let action = payload["action"] as? String else {
      isShowingSearch = false
      return
    }

    if action == "cancel" {
      isShowingSearch = false
      return
    }

    if action == "newContact" {
      isShowingSearch = true
      return
    }

    if action == "newGroup" || action == "newChannel" {
      isShowingSearch = false
      roomCreationName = ""
      if action == "newGroup" {
        isShowingGroupCreation = true
      } else {
        isShowingChannelCreation = true
      }
      return
    }

    guard
      ["select", "chat", "call", "saveContact"].contains(action),
      let rawUser = payload["user"] as? [String: Any],
      let user = ContactSearchUser(payload: rawUser)
    else {
      isShowingSearch = false
      errorMessage = "The selected user could not be opened."
      return
    }

    if action == "saveContact" {
      Task {
        await saveContact(for: user)
      }
      return
    }

    isShowingSearch = false
    Task {
      try? await Task.sleep(nanoseconds: 300_000_000)
      let route = await openChat(for: user)
      if action == "call", let route {
        NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
      }
    }
  }

  @MainActor
  private func createRoom(kind: ChatRoomCreationKind, name rawName: String) async {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return
    }

    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      errorMessage = "\(kind.displayName) name is required."
      return
    }

    isStartingChat = true
    errorMessage = nil
    defer { isStartingChat = false }

    do {
      let result = try await ChatRoomCreateService.create(kind: kind, config: config, name: name)
      let route = ChatRoute(
        chatId: result.chatID,
        title: result.name,
        peerUserId: nil,
        avatarURI: nil,
        isGroup: true,
        initialRows: []
      )
      coordinator.openChat(route)
      await model.refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func saveContact(for user: ContactSearchUser) async {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return
    }

    do {
      _ = try await ChatDirectMessageService.startChat(config: config, friendID: user.userID)
      await model.refresh()
      AppToastController.shared.show("Contact saved.")
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func openChat(for user: ContactSearchUser) async -> ChatRoute? {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return nil
    }

    isStartingChat = true
    errorMessage = nil
    defer { isStartingChat = false }

    do {
      let result = try await ChatDirectMessageService.startChat(config: config, friendID: user.userID)
      if let publicKey = user.publicKey, !publicKey.isEmpty {
        _ = ChatEngine.shared.cachePeerPublicKey([
          "chatId": result.chatID,
          "peerUserId": user.userID,
          "publicKey": publicKey,
        ])
      }
      let route = ChatRoute(
        chatId: result.chatID,
        title: user.username,
        peerUserId: user.userID,
        peerAgentId: user.bridgeAgentRouteId,
        isAgent: user.isAgent || user.bridgeProvider != nil,
        avatarURI: ChatAvatarURLResolver.resolve(
          rawAvatar: user.profileImage,
          peerUserId: user.userID,
          chatId: result.chatID,
          preferPushAvatar: true
        ),
        isGroup: false,
        initialRows: result.messages,
        bridgeProvider: user.bridgeProvider
      )
      coordinator.openChat(route)
      await model.refresh()
      return route
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }
}


private struct ChatHomeDeleteConfirmation: Identifiable {
  let id = UUID()
  let row: ChatHomeListRow

  var allowsDeleteForEveryone: Bool {
    row.peerUserId != nil && !row.isGroup && !row.isBuiltInAgentSurface
  }
}

private struct ChatHomePendingDeletion: Identifiable {
  let id = UUID()
  let row: ChatHomeListRow
  let deleteForEveryone: Bool
  let startedAt: Date
  let expiresAt: Date
  let duration: TimeInterval

  init(row: ChatHomeListRow, deleteForEveryone: Bool, duration: TimeInterval) {
    let now = Date()
    self.row = row
    self.deleteForEveryone = deleteForEveryone
    self.startedAt = now
    self.duration = duration
    self.expiresAt = now.addingTimeInterval(duration)
  }
}

private struct ChatHomeDeleteDialogView: View {
  let confirmation: ChatHomeDeleteConfirmation
  let palette: AppThemePalette
  let deleteForMe: () -> Void
  let deleteForEveryone: (() -> Void)?
  let cancel: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.28)
        .ignoresSafeArea()
        .onTapGesture(perform: cancel)

      VStack(spacing: 16) {
        ChatHomeDeleteAvatarView(row: confirmation.row, palette: palette)

        VStack(spacing: 5) {
          Text("Delete chat")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(palette.text)
            .lineLimit(1)

          Text("Are you sure you want to delete the chat with \(confirmation.row.title)?")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(palette.secondaryText)
            .multilineTextAlignment(.center)
        }

        VStack(spacing: 10) {
          if let deleteForEveryone {
            Button(role: .destructive, action: deleteForEveryone) {
              Text("Delete for me and \(confirmation.row.title)")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .buttonStyle(ChatHomeDialogButtonStyle(
              foreground: palette.danger,
              background: palette.input,
              border: palette.border
            ))
          }

          Button(role: .destructive, action: deleteForMe) {
            Text(deleteForEveryone != nil ? "Delete just for me" : "Delete for me")
              .font(.system(size: 16, weight: .semibold))
              .frame(maxWidth: .infinity)
              .frame(height: 48)
          }
          .buttonStyle(ChatHomeDialogButtonStyle(
            foreground: palette.danger,
            background: palette.input,
            border: palette.border
          ))

          Button(action: cancel) {
            Text("Cancel")
              .font(.system(size: 16, weight: .semibold))
              .frame(maxWidth: .infinity)
              .frame(height: 46)
          }
          .buttonStyle(ChatHomeDialogButtonStyle(
            foreground: palette.text,
            background: palette.input,
            border: palette.border
          ))
        }
      }
      .padding(20)
      .frame(maxWidth: 340)
      .background(AppHomeGlassEffectView(cornerRadius: 24))
      .overlay(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .stroke(palette.border, lineWidth: 1)
      )
      .shadow(color: Color.black.opacity(0.18), radius: 30, y: 16)
      .padding(.horizontal, 24)
    }
  }
}

private struct ChatHomeDialogButtonStyle: ButtonStyle {
  let foreground: Color
  let background: Color
  let border: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(foreground)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(configuration.isPressed ? background.opacity(0.74) : background)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(border, lineWidth: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

private struct ChatHomeDeleteAvatarView: View {
  let row: ChatHomeListRow
  let palette: AppThemePalette

  var body: some View {
    ZStack {
      Circle()
        .fill(avatarGradient)

      if let url = avatarURL {
        AsyncImage(url: url) { phase in
          if let image = phase.image {
            image
              .resizable()
              .scaledToFill()
          } else {
            fallback
          }
        }
      } else {
        fallback
      }
    }
    .frame(width: 72, height: 72)
    .clipShape(Circle())
    .overlay(Circle().stroke(Color.white.opacity(0.24), lineWidth: 1))
  }

  private var avatarURL: URL? {
    guard let avatarUri = row.avatarUri else { return nil }
    return URL(string: avatarUri)
  }

  private var fallback: some View {
    Text(String(row.avatarFallback.prefix(2)).uppercased())
      .font(.system(size: 24, weight: .bold))
      .foregroundStyle(.white)
  }

  private var avatarGradient: LinearGradient {
    let start = color(from: row.avatarGradientStartLight) ?? palette.accent
    let end = color(from: row.avatarGradientEndLight) ?? palette.button
    return LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  private func color(from raw: String?) -> Color? {
    guard var hex = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else {
      return nil
    }
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
    return Color(
      red: Double((value >> 16) & 0xff) / 255.0,
      green: Double((value >> 8) & 0xff) / 255.0,
      blue: Double(value & 0xff) / 255.0
    )
  }
}

private struct ChatHomeDeletionUndoToast: View {
  let deletion: ChatHomePendingDeletion
  let palette: AppThemePalette
  let undo: () -> Void

  var body: some View {
    TimelineView(.animation) { context in
      let remaining = max(0, deletion.expiresAt.timeIntervalSince(context.date))
      let progress = max(0, min(1, remaining / max(0.1, deletion.duration)))

      HStack(spacing: 12) {
        ZStack {
          Circle()
            .stroke(palette.border.opacity(0.65), lineWidth: 3)
          Circle()
            .trim(from: 0, to: progress)
            .stroke(
              palette.text.opacity(0.7),
              style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
          Text("\(Int(ceil(remaining)))")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(palette.text)
            .monospacedDigit()
        }
        .frame(width: 34, height: 34)

        Text("\(deletion.row.title) deleted")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(palette.text)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .center)

        Button(action: undo) {
          Text("Undo")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(
              RoundedRectangle(cornerRadius: 99, style: .continuous)
                .fill(palette.text.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
      }
      .padding(.leading, 12)
      .padding(.trailing, 10)
      .frame(maxWidth: .infinity)
      .frame(height: 58)
      .background(AppHomeGlassEffectView(cornerRadius: 99))
    }
  }
}

private struct AppHomeGlassEffectView: UIViewRepresentable {
  let cornerRadius: CGFloat

  func makeUIView(context: Context) -> UIVisualEffectView {
    let view = UIVisualEffectView(effect: nil)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = true
      view.effect = glass
      view.contentView.backgroundColor = .clear
    } else {
      view.effect = UIBlurEffect(style: .systemThinMaterial)
    }
    view.layer.cornerRadius = cornerRadius
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true
    return view
  }
  func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

private struct SettingsRootView: View {
  @EnvironmentObject private var coordinator: AppShellCoordinator
  var body: some View {
    NavigationStack(path: $coordinator.settingsPath) {
      SettingsView()
    }
    .onAppear { appShellRouteLog("SettingsRootView onAppear") }
    .onDisappear { appShellRouteLog("SettingsRootView onDisappear") }
  }
}


private enum ChatHomeRowAction: Equatable {
  case markUnread(Bool)
  case pin(Bool)
  case mute(Bool)
  case archive(Bool)
  case delete
}

private extension ChatHomeListRow {
  var hasUnreadState: Bool {
    unreadCount > 0 || markedUnread
  }

  var supportsRemoteHomeActions: Bool {
    !isSavedMessages && !isArchiveEntry && !isBuiltInAgentSurface
  }
}

private enum ChatHomeEditBulkAction {
  case markRead
  case mute
  case delete
}

private enum ChatHomeEditService {
  private enum EditError: LocalizedError {
    case invalidEndpoint
    case requestFailed(String)

    var errorDescription: String? {
      switch self {
      case .invalidEndpoint:
        return "Chat action endpoint is unavailable."
      case .requestFailed(let message):
        return message
      }
    }
  }

  static func apply(
    action: ChatHomeEditBulkAction,
    chatIDs: [String],
    config: AppSessionConfig
  ) async throws {
    for chatID in chatIDs {
      try await apply(action: action, chatID: chatID, config: config)
    }
  }

  static func apply(
    action: ChatHomeRowAction,
    chatID: String,
    config: AppSessionConfig
  ) async throws {
    let endpoint: String
    let method: String
    let body: [String: Any]?

    switch action {
    case .markUnread(let unread):
      endpoint = "/chat/\(chatID)/mark-unread"
      method = "POST"
      body = ["unread": unread]
    case .pin(let pinned):
      endpoint = "/chat/\(chatID)/pin"
      method = "POST"
      body = ["pinned": pinned]
    case .mute(let muted):
      endpoint = "/chat/\(chatID)/mute"
      method = "POST"
      body = ["muted": muted]
    case .archive(let archived):
      endpoint = "/chat/\(chatID)/archive"
      method = "POST"
      body = ["archived": archived]
    case .delete:
      endpoint = "/chats/\(chatID)"
      method = "DELETE"
      body = nil
    }

    try await performRequest(endpoint: endpoint, method: method, body: body, config: config)
  }

  static func deleteChat(
    chatID: String,
    config: AppSessionConfig,
    deleteForEveryone: Bool
  ) async throws {
    try await performRequest(
      endpoint: "/chats/\(chatID)",
      method: "DELETE",
      body: deleteForEveryone ? ["deleteForEveryone": true] : nil,
      config: config
    )
  }

  private static func apply(
    action: ChatHomeEditBulkAction,
    chatID: String,
    config: AppSessionConfig
  ) async throws {
    let endpoint: String
    let method: String
    let body: [String: Any]?

    switch action {
    case .markRead:
      endpoint = "/chat/\(chatID)/mark-unread"
      method = "POST"
      body = ["userId": config.userID, "unread": false]
    case .mute:
      endpoint = "/chat/\(chatID)/mute"
      method = "POST"
      body = ["userId": config.userID, "muted": true]
    case .delete:
      endpoint = "/chats/\(chatID)"
      method = "DELETE"
      body = nil
    }

    try await performRequest(endpoint: endpoint, method: method, body: body, config: config)
  }

  private static func performRequest(
    endpoint: String,
    method: String,
    body: [String: Any]?,
    config: AppSessionConfig
  ) async throws {
    guard let url = apiURL(base: config.apiBaseURLString, path: endpoint) else {
      throw EditError.invalidEndpoint
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw EditError.requestFailed(responseMessage(from: data))
    }
  }

  private static func apiURL(base rawBase: String, path: String) -> URL? {
    var base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    if base.hasSuffix("/api") {
      base = String(base.dropLast(4))
    }
    return URL(string: base + "/api" + path)
  }

  private static func responseMessage(from data: Data) -> String {
    if
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let message = (json["error"] ?? json["message"] ?? json["reason"]) as? String,
      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return message
    }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "Chat action failed."
  }
}

private struct ArchivedChatHomeListScreen: View {
  @ObservedObject var model: ChatsViewModel
  let palette: AppThemePalette
  let isDark: Bool
  let hiddenChatIDs: Set<String>
  let openRow: (ChatHomeListRow) -> Void
  let performAction: (ChatHomeRowAction, ChatHomeListRow) -> Void

  private var visibleRows: [ChatHomeListRow] {
    model.archivedRows.filter { !hiddenChatIDs.contains($0.chatId) }
  }

  var body: some View {
    Group {
      if visibleRows.isEmpty && model.isLoadingArchived {
        ProgressView()
          .controlSize(.regular)
          .tint(palette.secondaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(palette.background)
      } else if visibleRows.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "archivebox")
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(palette.secondaryText.opacity(0.75))
          Text("No Archived Chats")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(palette.text)
          Text("Archived conversations will appear here.")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(palette.secondaryText)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .background(palette.background)
      } else {
        ChatHomeNativeListRepresentable(
          rows: visibleRows,
          isDark: isDark,
          isEditing: false,
          showsRightCheckmark: false,
          selectedChatIDs: [],
          onSelect: openRow,
          onToggleSelection: { _ in },
          onAction: performAction,
          onRefresh: {
            await model.refreshArchived()
          },
          onUnavailableAction: { AppToastController.shared.show($0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
      }
    }
    .ignoresSafeArea(.container, edges: .top)
    .background(palette.background.ignoresSafeArea())
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await model.loadArchivedIfNeeded()
    }
  }
}

private struct ChatHomeEditActionBar: View {
  let selectedCount: Int
  let palette: AppThemePalette
  let onMarkRead: () -> Void
  let onMute: () -> Void
  let onDelete: () -> Void

  var body: some View {
    HStack(spacing: 20) {
      editActionButton(title: "Read", systemImage: "envelope.open", action: onMarkRead)
      editActionButton(title: "Mute", systemImage: "bell.slash", action: onMute)
      Text("\(selectedCount) selected")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(palette.secondaryText)
        .frame(maxWidth: .infinity)
      editActionButton(title: "Delete", systemImage: "trash", role: .destructive, action: onDelete)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private func editActionButton(
    title: String,
    systemImage: String,
    role: ButtonRole? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(role: role, action: action) {
      VStack(spacing: 3) {
        Image(systemName: systemImage)
          .font(.system(size: 18, weight: .medium))
        Text(title)
          .font(.system(size: 11, weight: .medium))
      }
      .frame(minWidth: 48)
    }
    .disabled(selectedCount == 0)
  }
}

private struct ChatShareSheetPresentationModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .background(Color.black.opacity(0.3).ignoresSafeArea())
      .presentationDetents([.medium, .large])
      .presentationContentInteraction(.resizes)
      .presentationDragIndicator(.hidden)
      .presentationCornerRadius(30)
  }
}

private extension View {
  func chatShareSheetPresentation() -> some View {
    modifier(ChatShareSheetPresentationModifier())
  }
}

private struct ShareChatSelectionView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model = ChatsViewModel()
  @State private var selectedChatIDs = Set<String>()
  let onSelect: ([String: Any]) -> Void

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    VStack(spacing: 0) {
      // Grabber Handle
      Capsule()
        .fill(palette.secondaryText.opacity(colorScheme == .dark ? 0.28 : 0.22))
        .frame(width: 36, height: 4)
        .padding(.top, 12)
        .padding(.bottom, 4)

      HStack {
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(palette.text)
            .frame(width: 44, height: 44, alignment: .leading)
        }
        
        Spacer()
        
        Text("Forward Messages")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(palette.text)
        
        Spacer()
        
        if !selectedChatIDs.isEmpty {
          Button {
            onSelect(["chatIds": Array(selectedChatIDs)])
          } label: {
            Image(systemName: "paperplane.fill")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(palette.accent)
              .frame(width: 44, height: 44, alignment: .trailing)
          }
        } else {
          Spacer()
            .frame(width: 44, height: 44)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 16)
      .padding(.bottom, 8)
      
      listContent
    }
    .task {
      await model.loadIfNeeded()
    }
  }

  @ViewBuilder
  private var listContent: some View {
    if model.rows.isEmpty && (!model.hasLoaded || model.isLoading) {
      ProgressView()
        .controlSize(.regular)
        .tint(palette.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    } else if model.rows.isEmpty {
      AppShellEmptyStateView(
        icon: "bubble.left.and.bubble.right",
        title: "No Chats",
        message: "You have no active chats to forward to.",
        buttonTitle: nil,
        palette: palette,
        action: nil
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.clear)
    } else {
      ChatHomeNativeListRepresentable(
        rows: model.rows,
        isDark: colorScheme == .dark,
        isEditing: false, // Turn off native left-side circles
        showsRightCheckmark: true,
        selectedChatIDs: selectedChatIDs,
        onSelect: { row in
          // Since isEditing is false, handle selection manually here
          if selectedChatIDs.contains(row.chatId) {
            selectedChatIDs.remove(row.chatId)
          } else {
            selectedChatIDs.insert(row.chatId)
          }
        },
        onToggleSelection: { _ in },
        onAction: { _, _ in },
        onRefresh: {
          await model.refresh()
        },
        onUnavailableAction: { _ in }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.clear)
    }
  }
}

private struct ChatHomeNativeListRepresentable: UIViewControllerRepresentable {
  let rows: [ChatHomeListRow]
  let isDark: Bool
  let isEditing: Bool
  let showsRightCheckmark: Bool
  let selectedChatIDs: Set<String>
  let onSelect: (ChatHomeListRow) -> Void
  let onToggleSelection: (String) -> Void
  let onAction: (ChatHomeRowAction, ChatHomeListRow) -> Void
  let onRefresh: () async -> Void
  let onUnavailableAction: (String) -> Void

  func makeUIViewController(context: Context) -> ChatHomeNativeListController {
    let controller = ChatHomeNativeListController()
    controller.onSelect = onSelect
    controller.onToggleSelection = onToggleSelection
    controller.onAction = onAction
    controller.onRefresh = onRefresh
    controller.onUnavailableAction = onUnavailableAction
    controller.apply(
      rows: rows,
      isDark: isDark,
      isEditing: isEditing,
      showsRightCheckmark: showsRightCheckmark,
      selectedChatIDs: selectedChatIDs
    )
    return controller
  }

  func updateUIViewController(_ uiViewController: ChatHomeNativeListController, context: Context) {
    uiViewController.onSelect = onSelect
    uiViewController.onToggleSelection = onToggleSelection
    uiViewController.onAction = onAction
    uiViewController.onRefresh = onRefresh
    uiViewController.onUnavailableAction = onUnavailableAction
    uiViewController.apply(
      rows: rows,
      isDark: isDark,
      isEditing: isEditing,
      showsRightCheckmark: showsRightCheckmark,
      selectedChatIDs: selectedChatIDs
    )
  }
}

private final class ChatHomeNativeListController: UIViewController, UITableViewDataSource,
  UITableViewDelegate, UIGestureRecognizerDelegate, ChatHomeCardCellSwipeDelegate
{
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let refreshControl = UIRefreshControl()
  private lazy var previewLongPressRecognizer: UILongPressGestureRecognizer = {
    let recognizer = UILongPressGestureRecognizer(
      target: self,
      action: #selector(handlePreviewLongPress(_:))
    )
    recognizer.minimumPressDuration = 0.24
    recognizer.allowableMovement = 10.0
    recognizer.delaysTouchesBegan = false
    recognizer.delaysTouchesEnded = false
    recognizer.cancelsTouchesInView = true
    recognizer.delegate = self
    return recognizer
  }()

  fileprivate var onSelect: (ChatHomeListRow) -> Void = { _ in }
  fileprivate var onToggleSelection: (String) -> Void = { _ in }
  fileprivate var onAction: (ChatHomeRowAction, ChatHomeListRow) -> Void = { _, _ in }
  fileprivate var onRefresh: (() async -> Void)?
  fileprivate var onUnavailableAction: (String) -> Void = { _ in }

  private var rows: [ChatHomeListRow] = []
  private var isDark = false
  private var isEditingMode = false
  private var showsRightCheckmark = false

  override var preferredStatusBarStyle: UIStatusBarStyle {
    return isDark ? .lightContent : .darkContent
  }
  private var selectedChatIDs = Set<String>()
  private var isRunningRefresh = false
  private var lastAppliedSignature = ""
  private weak var openSwipeCell: ChatHomeCardCell?
  private weak var heldPreviewCell: ChatHomeCardCell?
  private var suppressSelectionUntil: CFTimeInterval = 0

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    updateTopContentInset()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateTopContentInset()
  }

  // The SwiftUI host lets the table background extend under the transparent
  // navigation area. The row content still needs UIKit's safe-area clearance so
  // cells do not clip under the nav/search chrome.
  private func updateTopContentInset() {
    let topInset = view.safeAreaInsets.top
    guard tableView.contentInset.top != topInset else { return }
    tableView.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 24, right: 0)
    tableView.scrollIndicatorInsets = UIEdgeInsets(top: topInset, left: 0, bottom: 24, right: 0)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    AppUITrace.notice("ChatHomeNativeListController viewDidLoad")
    view.backgroundColor = .clear

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    tableView.sectionHeaderTopPadding = 0
    tableView.contentInsetAdjustmentBehavior = .never
    tableView.rowHeight = 84
    tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 24, right: 0)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(ChatHomeCardCell.self, forCellReuseIdentifier: ChatHomeCardCell.reuseIdentifier)
    tableView.refreshControl = refreshControl
    tableView.addGestureRecognizer(previewLongPressRecognizer)
    refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)

    view.addSubview(tableView)

    NSLayoutConstraint.activate([
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    if !rows.isEmpty {
      tableView.reloadData()
    }
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController viewDidLoad rows=\(rows.count)"
    )
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    AppUITrace.notice(
      "ChatHomeNativeListController viewWillAppear rows=\(rows.count) editing=\(isEditingMode ? "Y" : "N")"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController viewWillAppear rows=\(rows.count)"
    )
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    AppUITrace.notice(
      "ChatHomeNativeListController viewDidAppear rows=\(rows.count) contentSize=\(Int(tableView.contentSize.height)) offsetY=\(Int(tableView.contentOffset.y))"
    )
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    AppUITrace.notice(
      "ChatHomeNativeListController viewDidDisappear rows=\(rows.count) offsetY=\(Int(tableView.contentOffset.y))"
    )
  }

  func apply(
    rows: [ChatHomeListRow],
    isDark: Bool,
    isEditing: Bool,
    showsRightCheckmark: Bool,
    selectedChatIDs: Set<String>
  ) {
    let nextSignature = Self.signature(
      rows: rows,
      isDark: isDark,
      isEditing: isEditing,
      showsRightCheckmark: showsRightCheckmark,
      selectedChatIDs: selectedChatIDs
    )
    guard nextSignature != lastAppliedSignature else { return }
    let startedAt = ProcessInfo.processInfo.systemUptime
    let previousRows = self.rows
    let previousRowCount = self.rows.count
    let previousContentOffset = tableView.contentOffset
    AppUITrace.notice(
      "ChatHomeNativeListController apply start previousRows=\(previousRowCount) nextRows=\(rows.count) editing=\(isEditing ? "Y" : "N") selected=\(selectedChatIDs.count) offsetY=\(Int(previousContentOffset.y))"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController apply nextRows=\(rows.count) previousRows=\(previousRowCount)"
    )
    lastAppliedSignature = nextSignature
    let rowDelta = Self.animatableRowDelta(from: previousRows, to: rows)
    let canAnimateRowDelta = rowDelta != nil && isViewLoaded && view.window != nil && !isRunningRefresh
    let deletionOverlays = canAnimateRowDelta
      ? captureDeletionOverlays(for: rowDelta?.deletedIndexPaths ?? [])
      : []
    self.rows = rows
    self.isDark = isDark
    self.isEditingMode = isEditing
    self.showsRightCheckmark = showsRightCheckmark
    self.selectedChatIDs = selectedChatIDs

    guard isViewLoaded else {
      AppUITrace.notice(
        "ChatHomeNativeListController apply storedUntilViewLoad rows=\(rows.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))"
      )
      AppUIStallWatchdog.shared.updateContext(
        "ChatHomeNativeListController apply stored rows=\(rows.count)"
      )
      return
    }

    if canAnimateRowDelta, let rowDelta {
      performAnimatedRowDelta(rowDelta, deletionOverlays: deletionOverlays)
    } else {
      deletionOverlays.forEach { $0.removeFromSuperview() }
      let shouldPreserveOffset = previousRowCount == rows.count && !rows.isEmpty && view.window != nil
      UIView.performWithoutAnimation {
        tableView.reloadData()
        if shouldPreserveOffset {
          tableView.layoutIfNeeded()
          let minY = -tableView.adjustedContentInset.top
          let maxY = max(
            minY,
            tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
          )
          let y = min(max(previousContentOffset.y, minY), maxY)
          tableView.setContentOffset(CGPoint(x: previousContentOffset.x, y: y), animated: false)
        }
      }
    }
    AppUITrace.notice(
      "ChatHomeNativeListController apply done rows=\(rows.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)) contentSize=\(Int(tableView.contentSize.height)) offsetY=\(Int(tableView.contentOffset.y))"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController apply done rows=\(rows.count)"
    )
  }

  private struct AnimatableRowDelta {
    let deletedIndexPaths: [IndexPath]
    let insertedIndexPaths: [IndexPath]
  }

  private static func animatableRowDelta(
    from previousRows: [ChatHomeListRow],
    to nextRows: [ChatHomeListRow]
  ) -> AnimatableRowDelta? {
    let previousIDs = previousRows.map(\.chatId)
    let nextIDs = nextRows.map(\.chatId)
    let previousSet = Set(previousIDs)
    let nextSet = Set(nextIDs)

    guard previousSet.count == previousIDs.count, nextSet.count == nextIDs.count else { return nil }

    let deleted = previousIDs.enumerated().compactMap { index, chatId -> IndexPath? in
      nextSet.contains(chatId) ? nil : IndexPath(row: index, section: 0)
    }
    let inserted = nextIDs.enumerated().compactMap { index, chatId -> IndexPath? in
      previousSet.contains(chatId) ? nil : IndexPath(row: index, section: 0)
    }

    guard !deleted.isEmpty || !inserted.isEmpty else { return nil }
    guard deleted.count + inserted.count <= 4 else { return nil }

    let previousSharedOrder = previousIDs.filter { nextSet.contains($0) }
    let nextSharedOrder = nextIDs.filter { previousSet.contains($0) }
    guard previousSharedOrder == nextSharedOrder else { return nil }

    return AnimatableRowDelta(deletedIndexPaths: deleted, insertedIndexPaths: inserted)
  }

  private func captureDeletionOverlays(for indexPaths: [IndexPath]) -> [ChatHomeDeletionWipeOverlayView] {
    indexPaths.compactMap { indexPath in
      guard let cell = tableView.cellForRow(at: indexPath) as? ChatHomeCardCell else { return nil }
      let frame = tableView.convert(cell.frame, to: view)
      guard frame.intersects(view.bounds) else { return nil }
      let overlay = ChatHomeDeletionWipeOverlayView(
        frame: frame,
        snapshot: cell.contentView.snapshotView(afterScreenUpdates: false),
        isDark: isDark
      )
      view.addSubview(overlay)
      return overlay
    }
  }

  private func performAnimatedRowDelta(
    _ delta: AnimatableRowDelta,
    deletionOverlays: [ChatHomeDeletionWipeOverlayView]
  ) {
    tableView.performBatchUpdates {
      if !delta.deletedIndexPaths.isEmpty {
        tableView.deleteRows(at: delta.deletedIndexPaths, with: .none)
      }
      if !delta.insertedIndexPaths.isEmpty {
        tableView.insertRows(at: delta.insertedIndexPaths, with: .fade)
      }
    } completion: { _ in
      deletionOverlays.forEach { $0.animateAndRemove() }
    }
  }

  private static func signature(
    rows: [ChatHomeListRow],
    isDark: Bool,
    isEditing: Bool,
    showsRightCheckmark: Bool,
    selectedChatIDs: Set<String>
  ) -> String {
    let rowSignature = rows.map { row in
      [
        row.chatId,
        row.title,
        row.preview,
        row.timeLabel,
        "\(row.unreadCount)",
        "\(row.markedUnread)",
        "\(row.muted)",
        "\(row.pinned)",
        "\(row.archived)",
        "\(row.isTyping)",
        "\(row.isOnline)",
        row.avatarUri ?? "",
        row.peerTier ?? "",
      ].joined(separator: "\u{1F}")
    }
    return rowSignature.joined(separator: "||") + "||\(isDark ? "dark" : "light")||\(isEditing ? "edit" : "normal")||\(showsRightCheckmark ? "check" : "no_check")||\(selectedChatIDs.sorted().joined(separator: ","))"
  }

  @objc private func handleRefresh() {
    guard !isRunningRefresh else { return }
    isRunningRefresh = true
    AppUITrace.notice("ChatHomeNativeListController refresh start rows=\(rows.count)")
    AppUIStallWatchdog.shared.updateContext("ChatHomeNativeListController refresh rows=\(rows.count)")
    Task { @MainActor [weak self] in
      guard let self else { return }
      let startedAt = ProcessInfo.processInfo.systemUptime
      await onRefresh?()
      isRunningRefresh = false
      refreshControl.endRefreshing()
      AppUITrace.notice(
        "ChatHomeNativeListController refresh done rows=\(rows.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))"
      )
    }
  }

  @objc private func handlePreviewLongPress(_ recognizer: UILongPressGestureRecognizer) {
    switch recognizer.state {
    case .began:
      guard !isEditingMode, presentedViewController == nil else { return }
      let point = recognizer.location(in: tableView)
      guard
        let indexPath = tableView.indexPathForRow(at: point),
        rows.indices.contains(indexPath.row)
      else { return }

      let row = rows[indexPath.row]
      guard !row.isArchiveEntry else { return }
      openSwipeCell?.closeSwipe(animated: true)
      openSwipeCell = nil
      suppressSelectionUntil = CACurrentMediaTime() + 1.0

      guard let cell = tableView.cellForRow(at: indexPath) as? ChatHomeCardCell else { return }
      heldPreviewCell = cell
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      setPreviewHoldFeedback(cell, held: true, animated: true)

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self, weak recognizer, weak cell] in
        guard let self, let recognizer else { return }
        guard recognizer.state == .began || recognizer.state == .changed else {
          if let cell {
            self.setPreviewHoldFeedback(cell, held: false, animated: true)
          }
          return
        }
        guard self.presentedViewController == nil else {
          if let cell {
            self.setPreviewHoldFeedback(cell, held: false, animated: false)
          }
          return
        }
        if let cell {
          self.setPreviewHoldFeedback(cell, held: false, animated: false)
        }
        self.presentMiniPreview(for: row, sourceIndexPath: indexPath)
      }

    case .ended, .cancelled, .failed:
      suppressSelectionUntil = CACurrentMediaTime() + 0.7
      if presentedViewController == nil, let heldPreviewCell {
        setPreviewHoldFeedback(heldPreviewCell, held: false, animated: true)
      }
      heldPreviewCell = nil

    default:
      break
    }
  }

  private func setPreviewHoldFeedback(_ cell: ChatHomeCardCell, held: Bool, animated: Bool) {
    let changes = {
      cell.transform = held ? CGAffineTransform(scaleX: 0.965, y: 0.965) : .identity
    }
    if !animated {
      changes()
      return
    }
    UIView.animate(
      withDuration: held ? 0.18 : 0.24,
      delay: 0.0,
      usingSpringWithDamping: held ? 0.96 : 0.86,
      initialSpringVelocity: 0.0,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
      animations: changes
    )
  }

  private func presentMiniPreview(for row: ChatHomeListRow, sourceIndexPath: IndexPath) {
    let sourceFrame = tableView.rectForRow(at: sourceIndexPath)
    let sourceFrameInWindow = tableView.convert(sourceFrame, to: nil)
    let overlay = ChatHomeMiniPreviewOverlayController(
      row: row,
      isDark: isDark,
      sourceFrameInWindow: sourceFrameInWindow,
      onOpen: { [weak self] row in
        self?.onSelect(row)
      },
      onAction: { [weak self] action, row in
        self?.onAction(action, row)
      }
    )
    overlay.modalPresentationStyle = .overFullScreen
    overlay.modalTransitionStyle = .crossDissolve
    present(overlay, animated: false)
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    rows.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard
      let cell = tableView.dequeueReusableCell(
        withIdentifier: ChatHomeCardCell.reuseIdentifier,
        for: indexPath
      ) as? ChatHomeCardCell
    else {
      return UITableViewCell()
    }

    let row = rows[indexPath.row]
    cell.swipeDelegate = nil
    cell.setManualSwipeActionsEnabled(false)
    cell.selectionStyle = .none
    cell.backgroundColor = .clear
    cell.contentView.backgroundColor = .clear
    cell.configure(
      row: row,
      isDark: isDark,
      avatarBackgroundColor: nil,
      avatarGradientColors: resolvedAvatarGradientColors(for: row),
      isEditing: isEditingMode,
      isEditSelected: selectedChatIDs.contains(row.chatId),
      showsRightCheckmark: showsRightCheckmark
    )
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard rows.indices.contains(indexPath.row) else { return }
    if CACurrentMediaTime() < suppressSelectionUntil || presentedViewController != nil {
      tableView.deselectRow(at: indexPath, animated: false)
      return
    }
    openSwipeCell?.closeSwipe(animated: true)
    openSwipeCell = nil
    let row = rows[indexPath.row]
    AppUITrace.notice(
      "ChatHomeNativeListController didSelect row=\(indexPath.row) chatId=\(String(row.chatId.prefix(12))) title=\(row.title) editing=\(isEditingMode ? "Y" : "N") rows=\(rows.count)"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController didSelect chatId=\(String(row.chatId.prefix(12))) row=\(indexPath.row)"
    )
    if let cell = tableView.cellForRow(at: indexPath) as? ChatHomeCardCell {
      cell.flashPressedFeedback()
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if isEditingMode {
      let chatID = row.chatId
      onToggleSelection(chatID)
      if selectedChatIDs.contains(chatID) {
        selectedChatIDs.remove(chatID)
      } else {
        selectedChatIDs.insert(chatID)
      }
      tableView.reloadRows(at: [indexPath], with: .none)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
      self?.onSelect(row)
    }
    tableView.deselectRow(at: indexPath, animated: true)
  }

  func tableView(
    _ tableView: UITableView,
    leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    guard !isEditingMode, rows.indices.contains(indexPath.row) else { return nil }
    let row = rows[indexPath.row]
    guard row.supportsRemoteHomeActions else { return nil }

    let pin = UIContextualAction(
      style: .normal,
      title: row.pinned ? "Unpin" : "Pin"
    ) { [weak self] _, _, completion in
      self?.onAction(.pin(!row.pinned), row)
      completion(true)
    }
    pin.image = UIImage(systemName: row.pinned ? "pin.slash.fill" : "pin.fill")
    pin.backgroundColor = UIColor.systemBlue

    let hasUnread = row.hasUnreadState
    let unread = UIContextualAction(
      style: .normal,
      title: hasUnread ? "Read" : "Unread"
    ) { [weak self] _, _, completion in
      self?.onAction(.markUnread(!hasUnread), row)
      completion(true)
    }
    unread.image = UIImage(systemName: hasUnread ? "message.fill" : "circle.fill")
    unread.backgroundColor = UIColor.systemCyan

    let configuration = UISwipeActionsConfiguration(actions: [pin, unread])
    configuration.performsFirstActionWithFullSwipe = true
    return configuration
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    false
  }

  func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    guard !isEditingMode, rows.indices.contains(indexPath.row) else { return nil }
    let row = rows[indexPath.row]
    guard row.supportsRemoteHomeActions else { return nil }

    let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
      self?.onAction(.delete, row)
      completion(true)
    }
    delete.image = UIImage(systemName: "trash.fill")

    let archive = UIContextualAction(
      style: .normal,
      title: row.archived ? "Unarchive" : "Archive"
    ) { [weak self] _, _, completion in
      self?.onAction(.archive(!row.archived), row)
      completion(true)
    }
    archive.image = UIImage(systemName: row.archived ? "tray.and.arrow.up.fill" : "archivebox.fill")
    archive.backgroundColor = UIColor.systemGray

    let mute = UIContextualAction(
      style: .normal,
      title: row.muted ? "Unmute" : "Mute"
    ) { [weak self] _, _, completion in
      self?.onAction(.mute(!row.muted), row)
      completion(true)
    }
    mute.image = UIImage(systemName: row.muted ? "speaker.wave.2.fill" : "speaker.slash.fill")
    mute.backgroundColor = UIColor.systemOrange

    let configuration = UISwipeActionsConfiguration(actions: [delete, archive, mute])
    configuration.performsFirstActionWithFullSwipe = false
    return configuration
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    AppUITrace.notice(
      "ChatHomeNativeListController scrollBegin rows=\(rows.count) offsetY=\(Int(scrollView.contentOffset.y))"
    )
    openSwipeCell?.closeSwipe(animated: true)
    openSwipeCell = nil
  }

  func homeCardCellDidBeginSwipe(_ cell: ChatHomeCardCell) {
    if let indexPath = tableView.indexPath(for: cell), rows.indices.contains(indexPath.row) {
      AppUITrace.notice(
        "ChatHomeNativeListController swipeBegin row=\(indexPath.row) chatId=\(String(rows[indexPath.row].chatId.prefix(12)))"
      )
    } else {
      AppUITrace.notice("ChatHomeNativeListController swipeBegin row=unknown")
    }
    if openSwipeCell !== cell {
      openSwipeCell?.closeSwipe(animated: true)
    }
    openSwipeCell = cell
  }

  func homeCardCellDidCloseSwipe(_ cell: ChatHomeCardCell) {
    if openSwipeCell === cell {
      openSwipeCell = nil
    }
  }

  func homeCardCell(
    _ cell: ChatHomeCardCell,
    didTriggerSwipeEvent eventType: String,
    chatId: String
  ) {
    if openSwipeCell === cell {
      openSwipeCell = nil
    }
    AppUITrace.notice(
      "ChatHomeNativeListController swipeAction event=\(eventType) chatId=\(String(chatId.prefix(12)))"
    )
    guard let row = rows.first(where: { $0.chatId == chatId }) else {
      onUnavailableAction("Chat action is unavailable.")
      return
    }
    guard row.supportsRemoteHomeActions else {
      onUnavailableAction("This chat cannot be changed from Home.")
      return
    }

    switch eventType {
    case "swipePin":
      onAction(.pin(!row.pinned), row)
    case "swipeMarkRead":
      onAction(.markUnread(!row.hasUnreadState), row)
    case "swipeMute":
      onAction(.mute(!row.muted), row)
    case "swipeArchive":
      onAction(.archive(!row.archived), row)
    case "swipeDelete":
      onAction(.delete, row)
    default:
      onUnavailableAction("Chat action is unavailable.")
    }
  }

  private func resolvedAvatarGradientColors(for row: ChatHomeListRow) -> (UIColor, UIColor)? {
    if !row.isSavedMessages && !row.isArchiveEntry {
      return ChatProfileAppearanceStore.avatarColors(
        title: row.title,
        peerUserId: row.peerUserId,
        chatId: row.chatId
      )
    }

    let startRaw = isDark ? row.avatarGradientStartDark : row.avatarGradientStartLight
    let endRaw = isDark ? row.avatarGradientEndDark : row.avatarGradientEndLight
    guard let startRaw, let endRaw else { return nil }
    guard let startColor = Self.parseHexColor(startRaw), let endColor = Self.parseHexColor(endRaw)
    else { return nil }
    return (startColor, endColor)
  }

  private static func parseHexColor(_ raw: String) -> UIColor? {
    var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") {
      hex.removeFirst()
    }
    guard hex.count == 6 || hex.count == 8 else { return nil }

    var value: UInt64 = 0
    guard Scanner(string: hex).scanHexInt64(&value) else { return nil }

    if hex.count == 6 {
      let r = CGFloat((value >> 16) & 0xFF) / 255.0
      let g = CGFloat((value >> 8) & 0xFF) / 255.0
      let b = CGFloat(value & 0xFF) / 255.0
      return UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    let r = CGFloat((value >> 24) & 0xFF) / 255.0
    let g = CGFloat((value >> 16) & 0xFF) / 255.0
    let b = CGFloat((value >> 8) & 0xFF) / 255.0
    let a = CGFloat(value & 0xFF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: a)
  }
}

private final class ChatHomeDeletionWipeOverlayView: UIView {
  private let snapshotContainer = UIView()
  private let emitter = CAEmitterLayer()

  init(frame: CGRect, snapshot: UIView?, isDark: Bool) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = false
    layer.cornerCurve = .continuous

    snapshotContainer.frame = bounds
    snapshotContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(snapshotContainer)

    if let snapshot {
      snapshot.frame = snapshotContainer.bounds
      snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      snapshotContainer.addSubview(snapshot)
    }

    emitter.emitterPosition = CGPoint(x: bounds.width, y: bounds.midY)
    emitter.emitterSize = CGSize(width: 1, height: bounds.height)
    emitter.emitterShape = .line

    let cell = CAEmitterCell()
    cell.contents = createParticleImage(isDark: isDark)?.cgImage
    cell.birthRate = 6000
    cell.lifetime = 0.55
    cell.velocity = 500
    cell.velocityRange = 250
    cell.emissionLongitude = .pi // Point left
    cell.emissionRange = .pi / 6 // Slight spread
    cell.scale = 0.2
    cell.scaleRange = 0.1
    cell.scaleSpeed = -0.3
    cell.alphaSpeed = -1.5
    cell.yAcceleration = -400 // Go to top

    emitter.emitterCells = [cell]
    layer.addSublayer(emitter)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func animateAndRemove() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
      self.emitter.birthRate = 0
    }

    // Create a moving gradient mask so the cell image itself dissolves right-to-left
    let maskLayer = CAGradientLayer()
    maskLayer.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
    maskLayer.locations = [0.0, 0.05]
    maskLayer.startPoint = CGPoint(x: 1.0, y: 0.5) // Start right
    maskLayer.endPoint = CGPoint(x: 0.0, y: 0.5)   // End left
    maskLayer.frame = bounds
    snapshotContainer.layer.mask = maskLayer

    let duration: TimeInterval = 0.55

    let maskAnimation = CABasicAnimation(keyPath: "locations")
    maskAnimation.fromValue = [-0.1, 0.0]
    maskAnimation.toValue = [1.0, 1.1]
    maskAnimation.duration = duration * 0.8
    maskAnimation.fillMode = .forwards
    maskAnimation.isRemovedOnCompletion = false
    maskLayer.add(maskAnimation, forKey: "maskWipe")

    let moveEmitterAnimation = CABasicAnimation(keyPath: "emitterPosition.x")
    moveEmitterAnimation.fromValue = bounds.width
    moveEmitterAnimation.toValue = 0
    moveEmitterAnimation.duration = duration * 0.8
    moveEmitterAnimation.fillMode = .forwards
    moveEmitterAnimation.isRemovedOnCompletion = false
    emitter.add(moveEmitterAnimation, forKey: "moveEmitter")

    UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut, animations: {
      // Dissolves perfectly in place, no transform
    }) { _ in
      self.removeFromSuperview()
    }
  }

  private func createParticleImage(isDark: Bool) -> UIImage? {
    let size = CGSize(width: 1, height: 4) // Very thin slice
    UIGraphicsBeginImageContextWithOptions(size, false, 0)
    guard let context = UIGraphicsGetCurrentContext() else { return nil }
    context.setFillColor(isDark ? UIColor.white.withAlphaComponent(0.9).cgColor : UIColor.black.withAlphaComponent(0.9).cgColor)
    context.fill(CGRect(origin: .zero, size: size))
    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return image
  }
}

private protocol ChatHomePreviewActionMenuViewDelegate: AnyObject {
  func homePreviewActionMenu(_ menu: ChatHomePreviewActionMenuView, didSelect action: ChatHomePreviewActionMenuView.Action)
}

private func makeHomePreviewGlassView(
  style: UIBlurEffect.Style,
  cornerRadius: CGFloat,
  capsuleCorners: Bool = false,
  interactive: Bool = false
) -> UIVisualEffectView {
  let view = UIVisualEffectView(effect: nil)
  if #available(iOS 26.0, *) {
    let effect = UIGlassEffect(style: .regular)
    effect.isInteractive = interactive
    view.effect = effect
    if capsuleCorners {
      view.cornerConfiguration = .capsule()
    } else {
      view.layer.cornerRadius = cornerRadius
      view.layer.cornerCurve = .continuous
    }
  } else {
    view.effect = UIBlurEffect(style: style)
    view.layer.cornerRadius = cornerRadius
    view.layer.cornerCurve = .continuous
  }
  view.clipsToBounds = true
  return view
}

private final class ChatHomeMiniPreviewOverlayController: UIViewController,
  UIGestureRecognizerDelegate, ChatHomePreviewActionMenuViewDelegate
{
  private let backgroundGlassView: UIVisualEffectView
  private let colorOverlayView = UIView()
  private let previewGroupView = UIView()
  private let previewContainerView = UIView()
  private let menuView: ChatHomePreviewActionMenuView
  private let previewController: ChatHomeMiniPreviewController
  private let row: ChatHomeListRow
  private let isDark: Bool
  private let sourceFrameInWindow: CGRect
  private let onOpen: (ChatHomeListRow) -> Void
  private let onAction: (ChatHomeRowAction, ChatHomeListRow) -> Void
  private var isClosing = false
  private var ignoreBackdropTapUntil: CFTimeInterval = 0

  init(
    row: ChatHomeListRow,
    isDark: Bool,
    sourceFrameInWindow: CGRect,
    onOpen: @escaping (ChatHomeListRow) -> Void,
    onAction: @escaping (ChatHomeRowAction, ChatHomeListRow) -> Void
  ) {
    self.row = row
    self.isDark = isDark
    self.sourceFrameInWindow = sourceFrameInWindow
    self.onOpen = onOpen
    self.onAction = onAction
    self.backgroundGlassView = UIVisualEffectView(
      effect: UIBlurEffect(style: isDark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight)
    )
    self.menuView = ChatHomePreviewActionMenuView(row: row, isDark: isDark)
    self.previewController = ChatHomeMiniPreviewController(row: row, isDark: isDark)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    isDark ? .lightContent : .darkContent
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    backgroundGlassView.alpha = 0
    backgroundGlassView.frame = view.bounds
    backgroundGlassView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(backgroundGlassView)

    colorOverlayView.backgroundColor = (isDark ? UIColor.black : UIColor.white)
      .withAlphaComponent(isDark ? 0.34 : 0.24)
    colorOverlayView.frame = backgroundGlassView.contentView.bounds
    colorOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    backgroundGlassView.contentView.addSubview(colorOverlayView)

    previewGroupView.alpha = 0
    view.addSubview(previewGroupView)

    previewContainerView.clipsToBounds = true
    previewContainerView.layer.cornerRadius = 22
    previewContainerView.layer.cornerCurve = .continuous
    previewContainerView.layer.shadowColor = UIColor.black.cgColor
    previewContainerView.layer.shadowOpacity = isDark ? 0.28 : 0.18
    previewContainerView.layer.shadowRadius = 24
    previewContainerView.layer.shadowOffset = CGSize(width: 0, height: 14)
    previewGroupView.addSubview(previewContainerView)

    addChild(previewController)
    previewController.view.frame = previewContainerView.bounds
    previewController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    previewContainerView.addSubview(previewController.view)
    previewController.didMove(toParent: self)

    menuView.delegate = self
    menuView.alpha = 0
    previewGroupView.addSubview(menuView)

    let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleBackdropTap(_:)))
    tapRecognizer.delegate = self
    tapRecognizer.cancelsTouchesInView = false
    tapRecognizer.delaysTouchesBegan = false
    tapRecognizer.delaysTouchesEnded = false
    view.addGestureRecognizer(tapRecognizer)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard !isClosing else { return }
    backgroundGlassView.frame = view.bounds
    colorOverlayView.frame = backgroundGlassView.contentView.bounds
    layoutPreviewAndMenu()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    animateIn()
  }

  @discardableResult
  private func layoutPreviewAndMenu() -> CGRect {
    let bounds = view.bounds
    guard bounds.width > 1, bounds.height > 1 else { return .zero }

    let safeTop = view.safeAreaInsets.top + 14
    let safeBottom = bounds.height - view.safeAreaInsets.bottom - 14
    let safeLeft: CGFloat = 10
    let safeRight = bounds.width - 10
    let availableHeight = max(320, safeBottom - safeTop)

    let menuWidth = min(max(220, bounds.width * 0.54), min(268, bounds.width - 32))
    let menuHeight = menuView.systemLayoutSizeFitting(
      CGSize(width: menuWidth, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    ).height
    let menuGap: CGFloat = 4

    let previewWidth = min(max(300, bounds.width - 20), 560)
    let maxPreviewHeight = max(300, availableHeight - menuHeight - menuGap)
    let minPreviewHeight = min(maxPreviewHeight, min(380, max(320, availableHeight * 0.48)))
    let preferredPreviewHeight = min(bounds.height * 0.68, maxPreviewHeight)
    let previewHeight = max(minPreviewHeight, preferredPreviewHeight)
    let groupHeight = previewHeight + menuGap + menuHeight
    let sourceFrame = view.convert(sourceFrameInWindow, from: nil)
    let desiredGroupY = sourceFrame.midY - groupHeight * 0.22
    let groupY = max(safeTop, min(safeBottom - groupHeight, desiredGroupY))
    let previewX = max(safeLeft, min(safeRight - previewWidth, (bounds.width - previewWidth) * 0.5))
    let previewFrame = CGRect(x: previewX, y: groupY, width: previewWidth, height: previewHeight)

    let isRightAligned = sourceFrame.midX >= bounds.midX
    let menuX: CGFloat
    if isRightAligned {
      menuX = previewFrame.maxX - menuWidth - 12
    } else {
      menuX = previewFrame.minX + 12
    }
    let menuFrame = CGRect(
      x: max(safeLeft, min(safeRight - menuWidth, menuX)),
      y: previewFrame.maxY + menuGap,
      width: menuWidth,
      height: menuHeight
    )

    previewGroupView.frame = CGRect(
      x: 0,
      y: 0,
      width: bounds.width,
      height: bounds.height
    )
    previewContainerView.frame = previewFrame
    previewController.view.frame = previewContainerView.bounds
    menuView.frame = menuFrame
    previewContainerView.layer.shadowPath = UIBezierPath(
      roundedRect: previewContainerView.bounds,
      cornerRadius: previewContainerView.layer.cornerRadius
    ).cgPath
    return previewFrame
  }

  private func animateIn() {
    view.layoutIfNeeded()
    let finalPreviewFrame = layoutPreviewAndMenu()
    guard finalPreviewFrame.width > 1, finalPreviewFrame.height > 1 else { return }

    let sourceFrame = view.convert(sourceFrameInWindow, from: nil)
    let finalCenter = CGPoint(x: finalPreviewFrame.midX, y: finalPreviewFrame.midY)
    let sourceCenter = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
    let scaleX = max(0.12, min(1.0, sourceFrame.width / finalPreviewFrame.width))
    let scaleY = max(0.12, min(1.0, sourceFrame.height / finalPreviewFrame.height))

    previewGroupView.alpha = 1
    previewContainerView.center = sourceCenter
    previewContainerView.bounds = CGRect(origin: .zero, size: finalPreviewFrame.size)
    previewContainerView.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
    previewController.view.frame = previewContainerView.bounds

    let finalMenuFrame = menuView.frame
    menuView.frame = finalMenuFrame
    menuView.layer.anchorPoint = CGPoint(x: finalMenuFrame.midX >= view.bounds.midX ? 1.0 : 0.0, y: 0.0)
    menuView.center = CGPoint(x: finalMenuFrame.midX, y: finalMenuFrame.midY)
    menuView.transform = CGAffineTransform(translationX: 0, y: -4).scaledBy(x: 0.92, y: 0.92)

    menuView.isUserInteractionEnabled = false
    ignoreBackdropTapUntil = CACurrentMediaTime() + 0.65
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
      guard let self, !self.isClosing else { return }
      self.menuView.isUserInteractionEnabled = true
    }

    UIView.animate(
      withDuration: 0.20,
      delay: 0.0,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
    ) {
      self.backgroundGlassView.alpha = 1
    }

    UIView.animate(
      withDuration: 0.36,
      delay: 0.0,
      usingSpringWithDamping: 0.86,
      initialSpringVelocity: 0.0,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
    ) {
      self.previewContainerView.transform = .identity
      self.previewContainerView.center = finalCenter
    }

    UIView.animate(
      withDuration: 0.20,
      delay: 0.06,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
    ) {
      self.menuView.alpha = 1
    }
    UIView.animate(
      withDuration: 0.34,
      delay: 0.06,
      usingSpringWithDamping: 0.84,
      initialSpringVelocity: 0.0,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
    ) {
      self.menuView.transform = .identity
    }
  }

  @objc private func handleBackdropTap(_ recognizer: UITapGestureRecognizer) {
    guard CACurrentMediaTime() >= ignoreBackdropTapUntil else { return }
    close()
  }

  func homePreviewActionMenu(
    _ menu: ChatHomePreviewActionMenuView,
    didSelect action: ChatHomePreviewActionMenuView.Action
  ) {
    switch action {
    case .open:
      close(after: { [row, onOpen] in onOpen(row) })
    case .markUnread:
      close(after: { [row, onAction] in onAction(.markUnread(!row.hasUnreadState), row) })
    case .pin:
      close(after: { [row, onAction] in onAction(.pin(!row.pinned), row) })
    case .mute:
      close(after: { [row, onAction] in onAction(.mute(!row.muted), row) })
    case .archive:
      close(after: { [row, onAction] in onAction(.archive(!row.archived), row) })
    case .delete:
      close(after: { [row, onAction] in onAction(.delete, row) })
    }
  }

  private func close(after action: (() -> Void)? = nil) {
    guard !isClosing else { return }
    isClosing = true
    menuView.isUserInteractionEnabled = false

    let sourceFrame = view.convert(sourceFrameInWindow, from: nil)
    let finalPreviewFrame = previewContainerView.frame
    let scaleX = max(0.12, min(1.0, sourceFrame.width / max(1, finalPreviewFrame.width)))
    let scaleY = max(0.12, min(1.0, sourceFrame.height / max(1, finalPreviewFrame.height)))

    UIView.animate(
      withDuration: 0.18,
      delay: 0.0,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
    ) {
      self.backgroundGlassView.alpha = 0
      self.menuView.alpha = 0
      self.menuView.transform = CGAffineTransform(translationX: 0, y: -3).scaledBy(x: 0.94, y: 0.94)
      self.previewContainerView.center = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
      self.previewContainerView.transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
      self.previewContainerView.alpha = 0.0
    } completion: { _ in
      self.dismiss(animated: false, completion: action)
    }
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  {
    guard CACurrentMediaTime() >= ignoreBackdropTapUntil else { return false }
    let point = touch.location(in: view)
    if previewContainerView.frame.contains(point) { return false }
    if menuView.frame.contains(point) { return false }
    return true
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard CACurrentMediaTime() >= ignoreBackdropTapUntil else { return false }
    let point = gestureRecognizer.location(in: view)
    if previewContainerView.frame.contains(point) { return false }
    if menuView.frame.contains(point) { return false }
    return true
  }
}

private final class ChatHomePreviewActionMenuView: UIView {
  enum Action: String {
    case open
    case markUnread
    case pin
    case mute
    case archive
    case delete
  }

  weak var delegate: ChatHomePreviewActionMenuViewDelegate?

  private let glassView: UIVisualEffectView
  private let stackView = UIStackView()
  private let row: ChatHomeListRow
  private let isDark: Bool
  private var displayScale: CGFloat {
    let scale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
    return scale > 0 ? scale : 3
  }

  init(row: ChatHomeListRow, isDark: Bool) {
    self.row = row
    self.isDark = isDark

    let style: UIBlurEffect.Style = isDark ? .systemMaterialDark : .systemMaterialLight
    self.glassView = UIVisualEffectView(effect: UIBlurEffect(style: style))
    self.glassView.layer.cornerRadius = 18
    self.glassView.clipsToBounds = true
    self.glassView.layer.cornerCurve = .continuous
    super.init(frame: .zero)
    setup()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setup() {
    clipsToBounds = false
    glassView.translatesAutoresizingMaskIntoConstraints = false
    glassView.layer.borderColor = UIColor.white.withAlphaComponent(isDark ? 0.14 : 0.18).cgColor
    glassView.layer.borderWidth = 1.0 / displayScale
    addSubview(glassView)

    stackView.axis = .vertical
    stackView.spacing = 0
    stackView.translatesAutoresizingMaskIntoConstraints = false
    glassView.contentView.addSubview(stackView)

    NSLayoutConstraint.activate([
      glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
      glassView.topAnchor.constraint(equalTo: topAnchor),
      glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
      stackView.leadingAnchor.constraint(equalTo: glassView.contentView.leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: glassView.contentView.trailingAnchor),
      stackView.topAnchor.constraint(equalTo: glassView.contentView.topAnchor, constant: 8),
      stackView.bottomAnchor.constraint(equalTo: glassView.contentView.bottomAnchor, constant: -8),
    ])

    let actions = actionItems()
    for (index, item) in actions.enumerated() {
      if index > 0 {
        stackView.addArrangedSubview(separatorView())
      }
      let rowView = ChatHomePreviewActionRow(item: item, isDark: isDark)
      rowView.addTarget(self, action: #selector(handleRowTap(_:)), for: .touchUpInside)
      stackView.addArrangedSubview(rowView)
    }
  }

  private func actionItems() -> [ChatHomePreviewActionRow.Item] {
    var items: [ChatHomePreviewActionRow.Item] = [
      .init(action: .open, title: "Open Chat", iconName: "bubble.left.fill", isDestructive: false)
    ]
    guard row.supportsRemoteHomeActions else { return items }
    let hasUnread = row.hasUnreadState
    items.append(contentsOf: [
      .init(
        action: .markUnread,
        title: hasUnread ? "Mark as Read" : "Mark as Unread",
        iconName: hasUnread ? "envelope.open.fill" : "envelope.badge.fill",
        isDestructive: false
      ),
      .init(
        action: .pin,
        title: row.pinned ? "Unpin" : "Pin",
        iconName: row.pinned ? "pin.slash.fill" : "pin.fill",
        isDestructive: false
      ),
      .init(
        action: .mute,
        title: row.muted ? "Unmute" : "Mute",
        iconName: row.muted ? "speaker.wave.2.fill" : "speaker.slash.fill",
        isDestructive: false
      ),
      .init(
        action: .archive,
        title: row.archived ? "Unarchive" : "Archive",
        iconName: row.archived ? "tray.and.arrow.up.fill" : "archivebox.fill",
        isDestructive: false
      ),
      .init(action: .delete, title: "Delete", iconName: "trash.fill", isDestructive: true),
    ])
    return items
  }

  private func separatorView() -> UIView {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    let line = UIView()
    line.translatesAutoresizingMaskIntoConstraints = false
    line.backgroundColor = UIColor.label.withAlphaComponent(isDark ? 0.13 : 0.10)
    container.addSubview(line)
    let height = container.heightAnchor.constraint(equalToConstant: 1.0 / displayScale)
    height.priority = .defaultHigh
    NSLayoutConstraint.activate([
      height,
      line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 54),
      line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
      line.topAnchor.constraint(equalTo: container.topAnchor),
      line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return container
  }

  @objc private func handleRowTap(_ sender: ChatHomePreviewActionRow) {
    delegate?.homePreviewActionMenu(self, didSelect: sender.item.action)
  }
}

private final class ChatHomePreviewActionRow: UIControl {
  struct Item {
    let action: ChatHomePreviewActionMenuView.Action
    let title: String
    let iconName: String
    let isDestructive: Bool
  }

  let item: Item
  private let iconView = UIImageView()
  private let titleLabel = UILabel()

  init(item: Item, isDark: Bool) {
    self.item = item
    super.init(frame: .zero)
    backgroundColor = .clear

    let textColor: UIColor = item.isDestructive ? .systemRed : (isDark ? .white : .label)
    iconView.image = UIImage(
      systemName: item.iconName,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
    )
    iconView.tintColor = textColor
    iconView.contentMode = .scaleAspectFit
    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)

    titleLabel.text = item.title
    titleLabel.font = .systemFont(ofSize: 16.5, weight: .regular)
    titleLabel.textColor = textColor
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(titleLabel)

    let height = heightAnchor.constraint(equalToConstant: 40)
    height.priority = .defaultHigh
    NSLayoutConstraint.activate([
      height,
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 21),
      iconView.heightAnchor.constraint(equalToConstant: 21),
      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.10) {
        self.backgroundColor = self.isHighlighted ? UIColor.label.withAlphaComponent(0.08) : .clear
      }
    }
  }
}

private final class ChatHomeMiniPreviewController: UIViewController {
  private let backdropView: UIVisualEffectView
  private let mainView = ChatMainView()
  private let row: ChatHomeListRow
  private let isDark: Bool
  private var didInitialScrollToBottom = false
  private var openedChatChannel = false

  init(row: ChatHomeListRow, isDark: Bool) {
    self.row = row
    self.isDark = isDark
    let blurStyle: UIBlurEffect.Style = isDark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight
    self.backdropView = UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
    super.init(nibName: nil, bundle: nil)

    view.backgroundColor = .clear
    view.clipsToBounds = true

    backdropView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(backdropView)
    mainView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(mainView)
    NSLayoutConstraint.activate([
      backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      backdropView.topAnchor.constraint(equalTo: view.topAnchor),
      backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      mainView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      mainView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      mainView.topAnchor.constraint(equalTo: view.topAnchor),
      mainView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    backdropView.layer.cornerRadius = 20
    view.layer.cornerRadius = 20
    mainView.layer.cornerRadius = 20
    if #available(iOS 13.0, *) {
      backdropView.layer.cornerCurve = .continuous
      view.layer.cornerCurve = .continuous
      mainView.layer.cornerCurve = .continuous
    }
    backdropView.clipsToBounds = true
    mainView.clipsToBounds = true
    mainView.setExternalNavigationHeaderEnabled(false)
    mainView.setPreviewHeaderCenterOnly(true)
    mainView.setAppearance(Self.previewAppearance(isDark: isDark))
    mainView.surfaceId = "home_preview_\(row.chatId)"
    mainView.setEngineSurfaceId(mainView.surfaceId)
    mainView.setEngineChatId(row.chatId)
    mainView.setEnginePeerUserId(row.peerUserId ?? "")
    if let myUserId = Self.normalizedString(
      ChatEngineStore.shared.getConfig()["myUserId"] ?? ChatEngineStore.shared.getConfig()["userId"]
    ) {
      mainView.setEngineMyUserId(myUserId)
    }
    mainView.setHeaderTitle(row.title)
    mainView.setHeaderSubtitle(Self.headerSubtitle(for: row))
    mainView.setProfileName(row.title)
    mainView.setProfileHandle(Self.profileHandle(for: row))
    mainView.setAvatarUri(row.avatarUri)
    mainView.setIsOnline(Self.isOnline(for: row))
    mainView.setIsChatMuted(row.muted)
    mainView.setIsGroupOrChannel(row.isGroup)
    mainView.setStatusAuthorityEnabled(true)
    mainView.setInputBarEnabled(false)
    mainView.isUserInteractionEnabled = true
    mainView.setNativeSendEnabled(false)
    mainView.setPage(ChatConversationPage.chat.rawValue, animated: false)
    refreshPreviewRows()

    preferredContentSize = Self.preferredContentSize()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleChatEngineChanged(_:)),
      name: ChatEngine.didChangeNotification,
      object: nil
    )

    if row.supportsRemoteHomeActions {
      openedChatChannel = true
      _ = ChatEngine.shared.openChatChannel([
        "chatId": row.chatId,
        "peerUserId": row.peerUserId ?? "",
      ])
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    NotificationCenter.default.removeObserver(
      self,
      name: ChatEngine.didChangeNotification,
      object: nil
    )
    if openedChatChannel {
      _ = ChatEngine.shared.closeChatChannel(["chatId": row.chatId])
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    view.layoutIfNeeded()
    mainView.layoutIfNeeded()
    configurePreviewScrollBehavior()
  }

  private func refreshPreviewRows() {
    mainView.setRows(Self.previewRows(for: row))
    guard !didInitialScrollToBottom else { return }
    didInitialScrollToBottom = true
    DispatchQueue.main.async { [weak self] in
      self?.mainView.scrollToBottom(animated: false)
    }
  }

  private func configurePreviewScrollBehavior() {
    for scrollView in Self.collectScrollViews(in: mainView) {
      scrollView.isScrollEnabled = true
      scrollView.isDirectionalLockEnabled = true
      scrollView.bounces = false
      scrollView.alwaysBounceVertical = false
      scrollView.alwaysBounceHorizontal = false
      scrollView.panGestureRecognizer.cancelsTouchesInView = true
      scrollView.delaysContentTouches = false
      scrollView.canCancelContentTouches = true
    }
  }

  @objc private func handleChatEngineChanged(_ note: Notification) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleChatEngineChanged(note)
      }
      return
    }
    guard
      let changedChatId = Self.normalizedString(note.userInfo?["chatId"]),
      changedChatId == row.chatId
    else { return }

    let reason = Self.normalizedString(note.userInfo?["reason"]) ?? ""
    switch reason {
    case "peerTyping", "presenceChanged":
      mainView.setHeaderSubtitle(Self.headerSubtitle(for: row))
      mainView.setIsOnline(Self.isOnline(for: row))
      mainView.setProfileHandle(Self.profileHandle(for: row))
    case "chatRowsReloaded", "chatMessageInserted", "chatMessageEdited", "chatMessageDeleted",
      "chatMessageChanged", "messageStatusChanged":
      refreshPreviewRows()
    default:
      break
    }
  }

  private static func preferredContentSize() -> CGSize {
    let screen = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }
      .first ?? CGSize(width: 390, height: 844)
    let width = max(320, min(screen.width - 10, 560))
    let maxHeight = max(420, screen.height - 190)
    let height = min(maxHeight, screen.height * 0.72)
    return CGSize(width: width, height: height)
  }

  private static func previewRows(for row: ChatHomeListRow) -> [[String: Any]] {
    let engineRows = ChatEngine.shared.getChatRows(["chatId": row.chatId])
    if !engineRows.isEmpty {
      return engineRows
    }
    if !row.previewRows.isEmpty {
      return row.previewRows
    }
    if !row.initialMessages.isEmpty {
      return row.initialMessages
    }
    return fallbackPreviewRows(for: row)
  }

  private static func fallbackPreviewRows(for row: ChatHomeListRow) -> [[String: Any]] {
    let previewText =
      row.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Start a conversation"
      : row.preview
    let messageId = "preview_message_\(row.chatId)"
    let message: [String: Any] = [
      "id": messageId,
      "text": previewText,
      "timestamp": row.timeLabel,
      "isMe": false,
      "status": "sent",
      "type": "text",
      "isPinned": row.pinned,
      "bubbleShape": [
        "showTail": true,
        "borderTopLeftRadius": 18.0,
        "borderTopRightRadius": 18.0,
        "borderBottomLeftRadius": 4.0,
        "borderBottomRightRadius": 18.0,
      ],
    ]
    return [
      [
        "kind": "message",
        "key": messageId,
        "message": message,
      ]
    ]
  }

  private static func headerSubtitle(for row: ChatHomeListRow) -> String {
    if row.isSavedMessages {
      return "Saved Messages"
    }
    if ChatEngine.shared.isTyping(["chatId": row.chatId]) {
      return "typing..."
    }
    if isOnline(for: row) {
      return "online"
    }
    return row.isGroup ? "group" : "last seen recently"
  }

  private static func isOnline(for row: ChatHomeListRow) -> Bool {
    guard let peerUserId = normalizedString(row.peerUserId) else { return false }
    return ChatEngine.shared.isUserOnline(userId: peerUserId)
  }

  private static func profileHandle(for row: ChatHomeListRow) -> String {
    if row.isSavedMessages {
      return "saved chat"
    }
    if row.isGroup {
      return "group chat"
    }
    if let peer = normalizedString(row.peerUserId) {
      return "id: \(peer)"
    }
    return headerSubtitle(for: row)
  }

  private static func previewAppearance(isDark: Bool) -> [String: Any] {
    [
      "theme": isDark ? "dark" : "light",
      "backgroundMode": "gradient",
      "wallpaperOpacity": 1.0,
      "nativeThemeId": AppThemePlateController.currentOption.rawValue,
      "nativeThemeIsDark": isDark,
    ]
  }

  private static func collectScrollViews(in view: UIView) -> [UIScrollView] {
    var result: [UIScrollView] = []
    if let scrollView = view as? UIScrollView {
      result.append(scrollView)
    }
    for subview in view.subviews {
      result.append(contentsOf: collectScrollViews(in: subview))
    }
    return result
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }
}

private struct ContactsPageView: View {
  @EnvironmentObject private var coordinator: AppShellCoordinator
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model = ContactDirectoryViewModel()
  @State private var isShowingSearch = false
  @State private var isEditingContacts = false
  @State private var isStartingChat = false
  @State private var errorMessage: String?
  @State private var isShowingChannelCreation = false
  @State private var roomCreationName = ""
  @State private var isShowingGroupCreation = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    Group {

      Group {
        if model.rows.isEmpty && model.isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background)
        } else if model.rows.isEmpty {
          AppShellEmptyStateView(
            icon: "person.2",
            title: "No Contacts Yet",
            message: errorMessage ?? model.errorMessage ?? "Find someone by username, phone number, or user ID.",
            buttonTitle: "New Chat",
            palette: palette
          ) {
            isShowingSearch = true
          }
        } else {
          ChatHomeNativeListRepresentable(
            rows: model.rows,
            isDark: colorScheme == .dark,
            isEditing: isEditingContacts,
            showsRightCheckmark: false,
            selectedChatIDs: [],
            onSelect: { row in
              coordinator.openChat(ChatRoute(row: row))
            },
            onToggleSelection: { _ in },
            onAction: { _, _ in },
            onRefresh: { await model.refresh() },
            onUnavailableAction: { _ in }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(palette.background)
        }
      }
      .background(palette.background.ignoresSafeArea())
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(isEditingContacts ? "Done" : "Edit") {
            withAnimation { isEditingContacts.toggle() }
          }
          .font(.system(size: 17, weight: .semibold))
          .tint(colorScheme == .dark ? .white : .black)
        }

        ToolbarItem(placement: .principal) {
          Text("Contacts")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? .white : .black)
        }

        if !isEditingContacts {
          ToolbarItem(placement: .topBarTrailing) {
          HStack(spacing: 18) {
            Button {
            } label: {
              Image("BrandLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(colorScheme == .dark ? .white : .black)
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button {
            } label: {
              AppVectorIcon(glyph: .story, tint: colorScheme == .dark ? .white : .black)
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button {
              isShowingSearch = true
            } label: {
              AppVectorIcon(glyph: .compose, tint: colorScheme == .dark ? .white : .black)
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
          }
          .padding(.horizontal, 6)
        }
        }
      }
    }
    .task {
      await model.loadIfNeeded()
    }
    .refreshable {
      await model.refresh()
    }
    .sheet(isPresented: $isShowingSearch) {
      if let config = AppSessionConfig.current {
        Group {
          ContactSearchView(config: config, homeRows: model.rows) { payload in
            handleSearchPayload(payload)
          }
        }
      }
    }
    .sheet(isPresented: $isShowingGroupCreation) {
      if let config = AppSessionConfig.current {
        ChatGroupCreationSheet(config: config, homeRows: model.rows) { route in
          coordinator.openChat(route)
          Task { await model.refresh() }
        }
      }
    }
    .sheet(isPresented: $isShowingChannelCreation) {
      if let config = AppSessionConfig.current {
        ChannelCreationSheet(config: config) { route in
          coordinator.openChat(route)
          Task { await model.refresh() }
        }
      }
    }
  }

  private func handleSearchPayload(_ payload: [String: Any]) {
    guard let action = payload["action"] as? String else {
      isShowingSearch = false
      return
    }

    if action == "cancel" {
      isShowingSearch = false
      return
    }

    if action == "newContact" {
      isShowingSearch = true
      return
    }

    if action == "newGroup" || action == "newChannel" {
      isShowingSearch = false
      roomCreationName = ""
      if action == "newGroup" {
        isShowingGroupCreation = true
      } else {
        isShowingChannelCreation = true
      }
      return
    }

    guard
      ["select", "chat", "call", "saveContact"].contains(action),
      let rawUser = payload["user"] as? [String: Any],
      let user = ContactSearchUser(payload: rawUser)
    else {
      isShowingSearch = false
      errorMessage = "The selected contact could not be opened."
      return
    }

    if action == "saveContact" {
      Task {
        await saveContact(for: user)
      }
      return
    }

    isShowingSearch = false
    Task {
      let route = await openChat(for: user)
      if action == "call", let route {
        NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
      }
    }
  }

  @MainActor
  private func createRoom(kind: ChatRoomCreationKind, name rawName: String) async {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return
    }

    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      errorMessage = "\(kind.displayName) name is required."
      return
    }

    isStartingChat = true
    errorMessage = nil
    defer { isStartingChat = false }

    do {
      let result = try await ChatRoomCreateService.create(kind: kind, config: config, name: name)
      let route = ChatRoute(
        chatId: result.chatID,
        title: result.name,
        peerUserId: nil,
        avatarURI: nil,
        isGroup: true,
        initialRows: []
      )
      coordinator.openChat(route)
      await model.refresh()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func saveContact(for user: ContactSearchUser) async {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return
    }

    do {
      _ = try await ChatDirectMessageService.startChat(config: config, friendID: user.userID)
      await model.refresh()
      AppToastController.shared.show("Contact saved.")
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func openChat(for user: ContactSearchUser) async -> ChatRoute? {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return nil
    }

    isStartingChat = true
    errorMessage = nil
    defer { isStartingChat = false }

    do {
      let result = try await ChatDirectMessageService.startChat(config: config, friendID: user.userID)
      if let publicKey = user.publicKey, !publicKey.isEmpty {
        _ = ChatEngine.shared.cachePeerPublicKey([
          "chatId": result.chatID,
          "peerUserId": user.userID,
          "publicKey": publicKey,
        ])
      }
      let route = ChatRoute(
        chatId: result.chatID,
        title: user.username,
        peerUserId: user.userID,
        peerAgentId: user.bridgeAgentRouteId,
        isAgent: user.isAgent || user.bridgeProvider != nil,
        avatarURI: ChatAvatarURLResolver.resolve(
          rawAvatar: user.profileImage,
          peerUserId: user.userID,
          chatId: result.chatID,
          preferPushAvatar: true
        ),
        isGroup: false,
        initialRows: result.messages,
        bridgeProvider: user.bridgeProvider
      )
      coordinator.openChat(route)
      return route
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }
}

private struct CallsPageView: View {
  @Environment(\.colorScheme) private var colorScheme
  @State private var isEditingCalls = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    Group {
      AppShellEmptyStateView(
        icon: "phone",
        title: "No Calls Yet",
        message: "Recent and active calls will appear here when the call runtime is linked into the standalone shell.",
        buttonTitle: nil,
        palette: palette,
        action: nil
      )
      .background(palette.background.ignoresSafeArea())
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(isEditingCalls ? "Done" : "Edit") {
            withAnimation { isEditingCalls.toggle() }
          }
          .font(.system(size: 17, weight: .semibold))
          .tint(colorScheme == .dark ? .white : .black)
        }

        ToolbarItem(placement: .principal) {
          Text("Calls")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? .white : .black)
        }

        if !isEditingCalls {
          ToolbarItem(placement: .topBarTrailing) {
          HStack(spacing: 18) {
            Button {
            } label: {
              Image("BrandLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(colorScheme == .dark ? .white : .black)
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button {
            } label: {
              AppVectorIcon(glyph: .story, tint: colorScheme == .dark ? .white : .black)
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button {
            } label: {
              AppVectorIcon(glyph: .compose, tint: colorScheme == .dark ? .white : .black)
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
          }
          .padding(.horizontal, 6)
        }
        }
      }
    }
  }
}





private enum ChatConversationPage: String {
  case chat
  case profile
  case agent
}

final class ChatProfileRootController: UIViewController {
  private let profileView = ChatProfileMainView()
  private var route: ChatRoute
  private var isDark: Bool
  private var onClose: (() -> Void)?

  init(route: ChatRoute, isDark: Bool, onClose: (() -> Void)?) {
    self.route = route
    self.isDark = isDark
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
    appShellRouteLog("ChatProfileRootController init chatId=\(route.chatId) title=\(route.title)")
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    return isDark ? .lightContent : .darkContent
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = Self.backgroundColor(isDark: isDark)
    profileView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(profileView)
    NSLayoutConstraint.activate([
      profileView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      profileView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      profileView.topAnchor.constraint(equalTo: view.topAnchor),
      profileView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    profileView.onNativeEvent.handler = { [weak self] payload in
      self?.handleNativeEvent(payload)
    }
    applyRoute()
  }

  func update(route: ChatRoute, isDark: Bool, onClose: (() -> Void)?) {
    let routeChanged = self.route != route
    let themeChanged = self.isDark != isDark
    self.route = route
    self.isDark = isDark

    if themeChanged {
      setNeedsStatusBarAppearanceUpdate()
      view.backgroundColor = Self.backgroundColor(isDark: isDark)
    }
    if routeChanged || themeChanged {
      applyRoute()
    }
  }

  private func applyRoute() {
    let surfaceId = "native_profile_\(route.chatId)"
    view.backgroundColor = Self.backgroundColor(isDark: isDark)
    profileView.surfaceId = surfaceId
    profileView.setProfileOnly(true)
    profileView.setEngineSurfaceId(surfaceId)
    profileView.setEngineChatId(route.chatId)
    profileView.setEnginePeerUserId(route.peerUserId ?? "")
    if let myUserId = Self.normalizedString(
      ChatEngineStore.shared.getConfig()["myUserId"] ?? ChatEngineStore.shared.getConfig()["userId"]
    ) {
      profileView.setEngineMyUserId(myUserId)
    }
    profileView.setAppearance(Self.resolvedAppearance(isDark: isDark))
    profileView.setHeaderTitle(route.title)
    profileView.setHeaderSubtitle(Self.routeOnlyHeaderSubtitle(for: route))
    profileView.setProfileName(route.title)
    profileView.setBridgeProvider(route.bridgeProvider ?? "")
    profileView.setProfileHandle(Self.profileHandle(for: route))
    profileView.setProfileBio("")
    profileView.setAvatarUri(route.avatarURI)
    profileView.setIsGroupOrChannel(route.isGroup)
    profileView.setRows(route.initialRows)
  }

  private func handleNativeEvent(_ payload: [String: Any]) {
    let type = Self.normalizedString(payload["type"]) ?? ""
    appShellRouteLog("ChatProfileRootController nativeEvent chatId=\(route.chatId) type=\(type)")
    switch type {
    case "headerBack":
      onClose?()
    case "headerSearchPressed":
      AppToastController.shared.show("Search stays in the chat page.")
    case "headerAudioCallPressed":
      NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
    case "headerVideoCallPressed":
      NativeCallRouteBridge.startOutgoing(route: route, callType: "video")
    case "headerMenuAction":
      let action = Self.normalizedString(payload["action"]) ?? ""
      if action == "clearChat" {
        presentClearChatOptions()
      }
    default:
      break
    }
  }

  private func presentClearChatOptions() {
    let presenter = topMostPresenter()
    let canClearForEveryone = route.peerUserId != nil && !route.isGroup && route.chatId != "saved_messages"
    let sheet = UIAlertController(
      title: "Clear Chat",
      message: nil,
      preferredStyle: .actionSheet
    )
    if canClearForEveryone {
      sheet.addAction(
        UIAlertAction(title: "Clear for me and \(route.title)", style: .destructive) {
          [weak self] _ in
          self?.performClearChat(deleteForEveryone: true)
        })
    }
    sheet.addAction(
      UIAlertAction(
        title: canClearForEveryone ? "Clear just for me" : "Clear for me",
        style: .destructive
      ) { [weak self] _ in
        self?.performClearChat(deleteForEveryone: false)
      })
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: view.safeAreaInsets.top + 44.0, width: 1.0, height: 1.0)
      popover.permittedArrowDirections = []
    }
    presenter.present(sheet, animated: true)
  }

  private func topMostPresenter() -> UIViewController {
    var presenter: UIViewController = self
    while let presented = presenter.presentedViewController {
      presenter = presented
    }
    return presenter
  }

  private func performClearChat(deleteForEveryone: Bool) {
    if deleteForEveryone {
      _ = ChatEngine.shared.clearChat([
        "chatId": route.chatId,
        "localOnly": true,
      ])
      profileView.setRows([])
      guard let config = AppSessionConfig.current else {
        AppToastController.shared.show("The current session is unavailable.")
        return
      }
      Task { @MainActor in
        do {
          try await ChatHomeEditService.deleteChat(
            chatID: route.chatId,
            config: config,
            deleteForEveryone: true
          )
          AppToastController.shared.show("Chat cleared for both sides.")
        } catch {
          AppToastController.shared.show(error.localizedDescription)
        }
      }
      return
    }

    _ = ChatEngine.shared.clearChat(["chatId": route.chatId])
    profileView.setRows([])
    AppToastController.shared.show("Chat cleared.")
  }

  private static func backgroundColor(isDark: Bool) -> UIColor {
    isDark
      ? UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
      : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
  }

  private static func resolvedAppearance(isDark: Bool) -> [String: Any] {
    [
      "theme": isDark ? "dark" : "light",
      "backgroundMode": "gradient",
      "wallpaperOpacity": 1.0,
      "nativeThemeId": AppThemePlateController.currentOption.rawValue,
      "nativeThemeIsDark": isDark,
    ]
  }

  private static func routeOnlyHeaderSubtitle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Saved Messages"
    }
    if route.isGroup {
      return "group"
    }
    return route.peerUserId == nil ? "" : "last seen recently"
  }

  private static func profileHandle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Personal notes and media"
    }
    if let peerUserId = normalizedString(route.peerUserId) {
      return peerUserId
    }
    return route.isGroup ? "Group chat" : ""
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }
}

final class ChatConversationController: UIViewController {
  private static let postPresentationActivationDelay: TimeInterval = 0.28

  private let mainView = ChatMainView()
  private var profileView: ChatProfileMainView?
  private var route: ChatRoute
  private var isDark: Bool
  private var onClose: (() -> Void)?
  private var currentPage: ChatConversationPage = .chat
  private var openedChatId: String?
  private var openedChatIdUsesEngineChannel = false
  private var didInitialScroll = false
  private var rowsRefreshGeneration: UInt = 0
  private var lastLayoutSignature: String?
  private var hasAppeared = false
  private var pendingDeferredEngineStateRefresh = false
  private var deferredEngineRowsReadyChatId: String?
  private var latestProfileRows: [[String: Any]] = []
  private var pendingRowsForAttachment: [[String: Any]]?
  private var isDismantled = false
  private var pendingRowsForAttachmentChatId: String?
  private var pendingRowsForAttachmentSource: String?
  private var lastAppliedRowsToSurfaceCount = 0
  private var postPresentationActivationWorkItem: DispatchWorkItem?
  private var didRunPostPresentationActivation = false
  private var pendingEngineBinding = false
  private var engineBindingKey: String?
  private var engineBindingUserId: String?
  private var pendingAppearanceForAttachment: [String: Any]?
  private var pendingInputActivationForAttachment = false
  // Computer-bridge agent (Claude/Codex) connect gate. Non-nil while the chat is
  // an unconnected bridge-agent chat: the composer is hidden and a Connect panel
  // is shown until a paired computer comes online.
  private var agentConnectModel: AgentConnectModel?
  private var agentConnectHost: UIHostingController<AgentConnectPanel>?
  private var bridgeConnectedThisSession = false
  /// Pending "show the connect panel" work, deferred a beat so a fast status poll can
  /// reveal the composer with no panel flash. Cancelled the moment we connect.
  private var pendingConnectPanelWork: DispatchWorkItem?
  /// Fresh bridge status verification before the connect panel is allowed to appear.
  /// This prevents a stale disconnected route state from flashing the panel for a
  /// second while the daemon is already online.
  private var pendingConnectStatusTask: Task<Void, Never>?

  /// The isolated full-screen agent runtime surface (Claude/Codex), hosted as a child VC
  /// over `mainView` when this DM's Default view is Agent or the user taps "See progress".
  /// It owns its full bounds + its own header (no nesting under the chat header → no clip /
  /// overlap), and its back returns to the chat surface.
  private weak var bridgeAgentSurfaceVC: VibeAgentConversationViewController?

  /// The chat currently shown. Used by the coordinator to avoid pushing a
  /// duplicate of the chat already on top of the navigation stack.
  var chatId: String { route.chatId }

  init(route: ChatRoute, isDark: Bool, onClose: (() -> Void)?) {
    self.route = route
    self.isDark = isDark
    self.onClose = onClose
    appShellRouteLog(
      "ChatConversationController init chatId=\(route.chatId) title=\(route.title) dark=\(isDark)")
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    return isDark ? .lightContent : .darkContent
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    logLifecycle("viewDidLoad")

    mainView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(mainView)
    NSLayoutConstraint.activate([
      mainView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      mainView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      mainView.topAnchor.constraint(equalTo: view.topAnchor),
      mainView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    mainView.onNativeEvent.handler = { [weak self] payload in
      self?.handleNativeEvent(payload)
    }
    // Host the DM-level agent runtime view as an isolated full-screen surface over the
    // chat (its own header + full bounds). ChatListView's presence logic drives these.
    mainView.onPresentBridgeAgentSurface = { [weak self] vc in
      self?.presentBridgeAgentSurface(vc)
    }
    mainView.onDismissBridgeAgentSurface = { [weak self] in
      self?.dismissBridgeAgentSurface()
    }
    mainView.hostedBridgeAgentProviderProvider = { [weak self] in
      self?.bridgeAgentSurfaceVC?.agentBridgeProvider
    }
    // Draw the chat's own native header (back / title / avatar). The view fully
    // implements this; it was only disabled so a SwiftUI .toolbar could draw the
    // header instead — the source of the header flicker. Now that the
    // conversation is pushed by a real UIKit UINavigationController (with the
    // system bar hidden), it owns exactly one stable header.
    mainView.setExternalNavigationHeaderEnabled(false)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleChatEngineChanged(_:)),
      name: ChatEngine.didChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAgentBridgeSelectionChanged(_:)),
      name: AgentBridgeSelectionStore.didChangeNotification,
      object: nil
    )

    applyRoute(forceChannelRefresh: true)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    logLifecycle("viewWillAppear")
    logVisualState("viewWillAppear", force: true)
    // If this DM's Default view is Agent, mount the isolated agent surface NOW so it rides this
    // controller's own push transition AS the page — rather than waiting for the deferred peer-id
    // binding (~0.28s after viewDidAppear), which would show the chat first and then morph the
    // agent in over it. ChatListView gates on the per-provider Default-view setting and is
    // one-shot + idempotent, so calling this on every appear is safe.
    mountPreferredAgentSurfaceIfNeeded(reason: "viewWillAppear")
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !isDismantled else { return }
    hasAppeared = true
    logLifecycle("viewDidAppear")
    logVisualState("viewDidAppear", force: true)
    applyPendingAppearanceAfterAttachment(reason: "viewDidAppear")
    applyPendingInputActivationAfterAttachment(reason: "viewDidAppear")
    applyPendingRowsAfterAttachment(reason: "viewDidAppear")
    settleInitialBottomIfNeeded(reason: "viewDidAppear")
    schedulePostPresentationActivation(reason: "viewDidAppear")
    refreshPersistentAgentInboxSummary()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyPendingAppearanceAfterAttachment(reason: "viewDidLayoutSubviews")
    applyPendingInputActivationAfterAttachment(reason: "viewDidLayoutSubviews")
    applyPendingRowsAfterAttachment(reason: "viewDidLayoutSubviews")
    settleInitialBottomIfNeeded(reason: "viewDidLayoutSubviews")
    logVisualState("viewDidLayoutSubviews")
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    logLifecycle("viewDidDisappear")
    logVisualState("viewDidDisappear", force: true)
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    logLifecycle("didMoveToParent")
    logVisualState("didMoveToParent", force: true)
  }

  deinit {
    NotificationCenter.default.removeObserver(
      self,
      name: ChatEngine.didChangeNotification,
      object: nil
    )
    NotificationCenter.default.removeObserver(
      self,
      name: AgentBridgeSelectionStore.didChangeNotification,
      object: nil
    )
    postPresentationActivationWorkItem?.cancel()
    pendingConnectStatusTask?.cancel()
    closeOpenedChatChannel()
  }

  func dismantle() {
    logLifecycle("dismantle")
    isDismantled = true
    postPresentationActivationWorkItem?.cancel()
    postPresentationActivationWorkItem = nil
    removeAgentConnectPanel()
    closeOpenedChatChannel()
  }

  func update(route: ChatRoute, isDark: Bool, onClose: (() -> Void)?) {
    let chatChanged = self.route.chatId != route.chatId
    let themeChanged = self.isDark != isDark
    appShellRouteLog(
      "ChatConversationController update oldChatId=\(self.route.chatId) newChatId=\(route.chatId) chatChanged=\(chatChanged) themeChanged=\(themeChanged)")
    self.route = route
    self.isDark = isDark
    self.onClose = onClose
    applyRoute(forceChannelRefresh: chatChanged)
    if themeChanged {
      setNeedsStatusBarAppearanceUpdate()
      applySurfaceAppearance(
        Self.resolvedAppearance(isDark: isDark),
        reason: "themeChanged",
        allowDeferUntilAttached: true
      )
    }
  }

  func handleNavigationAction(_ action: AppChatNavigationAction) {
    switch action {
    case .avatar:
      guard route.chatId != "saved_messages", !route.isAgentChat else { return }
      showProfileView(animated: true)
    }
  }

  func represents(_ route: ChatRoute) -> Bool {
    self.route == route
  }

  private func applyRoute(forceChannelRefresh: Bool) {
    view.backgroundColor = Self.backgroundColor(isDark: isDark)
    // Clear any previous bridge-agent connect gate before reconfiguring; the input
    // activation below re-establishes it when the new route is an unconnected agent.
    resetAgentConnectGate()
    currentPage = .chat
    appShellRouteLog(
      "ChatConversationController applyRoute chatId=\(route.chatId) title=\(route.title) forceRefresh=\(forceChannelRefresh) initialRows=\(route.initialRows.count)")

    let deferSurfaceUntilAttached = view.window == nil && !hasAppeared
    postPresentationActivationWorkItem?.cancel()
    postPresentationActivationWorkItem = nil
    didRunPostPresentationActivation = false
    pendingEngineBinding = true
    pendingDeferredEngineStateRefresh = true
    deferredEngineRowsReadyChatId = nil
    if deferSurfaceUntilAttached {
      appShellRouteLog(
        "ChatConversationController deferEngineState chatId=\(route.chatId) reason=prePresentation")
    } else {
      appShellRouteLog(
        "ChatConversationController deferEngineState chatId=\(route.chatId) reason=routeActivation")
    }

    let surfaceId = "native_chat_\(route.chatId)"
    latestProfileRows = route.initialRows
    lastAppliedRowsToSurfaceCount = 0
    mainView.surfaceId = surfaceId
    mainView.setDefersEngineStateRefreshes(true)
    mainView.setStatusAuthorityEnabled(false)
    mainView.setEngineChannelBindingEnabled(false)
    if deferSurfaceUntilAttached {
      appShellRouteLog(
        "ChatConversationController deferEngineBinding chatId=\(route.chatId) reason=prePresentation")
    } else {
      configureEngineBindingIfNeeded(reason: "applyRoute", enableStatusAuthority: false)
    }
    applySurfaceAppearance(
      Self.resolvedAppearance(isDark: isDark),
      reason: "applyRoute",
      allowDeferUntilAttached: deferSurfaceUntilAttached
    )
    appShellRouteLog(
      "ChatConversationController configureRouteSurfaceStart chatId=\(route.chatId) reason=applyRoute")
    markRouteSurfaceStep("header")
    mainView.setHeaderMode(route.chatId == "saved_messages" ? "savedmessages" : "default")
    mainView.setBridgeProvider(route.bridgeProvider ?? "")
    mountPreferredAgentSurfaceIfNeeded(reason: "applyRoute")
    mainView.setHeaderTitle(route.title)
    mainView.setHeaderUnreadCount(route.unreadCount)
    mainView.setProfileName(route.title)
    mainView.setProfileHandle(Self.profileHandle(for: route))
    mainView.setProfileBio("")
    markRouteSurfaceStep("avatar")
    mainView.setAvatarUri(route.avatarURI)
    markRouteSurfaceStep("groupAndInput")
    mainView.setIsGroupOrChannel(route.isGroup)
    // When the chat talks to an AI agent, bind the agent id so the engine routes
    // sends to the agent backend (peerAgentId) instead of E2E-encrypting to a
    // human peer. Empty string clears it for normal peer/group chats.
    mainView.setEnginePeerAgentId(route.peerAgentId ?? "")
    appShellRouteLog(
      "ChatConversationController agentRouting chatId=\(route.chatId) peerUserId=\(route.peerUserId ?? "nil") peerAgentId=\(route.peerAgentId ?? "nil") bridgeProvider=\(route.bridgeProvider ?? "nil") isAgent=\(route.isAgent) isAgentChat=\(route.isAgentChat)")
    // Inbox mode: when the attached agent batches events, the chat view keeps the
    // transcript clean and surfaces event notifications behind the Inbox banner.
    mainView.setAgentEventInboxMode(enabled: route.isAgentInboxMode)
    refreshPersistentAgentInboxSummary()
    mainView.setInputPlaceholder(
      route.chatId == "saved_messages"
        ? "Saved Message"
        : (route.isAgentChat ? "Message \(route.title)" : "Message"))
    if deferSurfaceUntilAttached {
      pendingInputActivationForAttachment = true
      appShellRouteLog(
        "ChatConversationController deferInputActivation chatId=\(route.chatId) reason=prePresentation")
    } else {
      applyInputActivation(reason: "applyRoute")
    }
    markRouteSurfaceStep("page")
    mainView.setStandaloneProfileMode(false)
    // setStandaloneProfileMode(false) re-enables the composer — re-assert the
    // bridge-agent gate so an unconnected Claude/Codex chat stays input-less.
    if !deferSurfaceUntilAttached, let provider = route.bridgeProvider, !provider.isEmpty,
      !bridgeConnectedThisSession
    {
      applyAgentConnectGate(provider: provider, reason: "applyRoute-afterProfileMode")
    }
    mainView.setPage(ChatConversationPage.chat.rawValue, animated: false)
    removeProfileView(animated: false)
    appShellRouteLog(
      "ChatConversationController configuredSurface chatId=\(route.chatId) surfaceId=\(surfaceId) peerUserId=\(route.peerUserId ?? "") isGroup=\(route.isGroup) headerMode=\(route.chatId == "saved_messages" ? "savedmessages" : "default") windowAttached=\(view.window != nil)")

    refreshRouteOnlyHeaderState()
    refreshRows(preferInitialRows: true)
    logVisualState("afterApplyRoute", force: true)

    if forceChannelRefresh {
      closeOpenedChatChannel()
    }
    if hasAppeared, view.window != nil {
      schedulePostPresentationActivation(reason: "applyRouteAttached")
    } else {
      appShellRouteLog(
        "ChatConversationController deferOpenChatChannel chatId=\(route.chatId) reason=prePresentation hasAppeared=\(hasAppeared) windowAttached=\(view.window != nil)")
    }
  }

  private func markRouteSurfaceStep(_ step: String) {
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController configureRouteSurface.\(step) chatId=\(route.chatId) reason=applyRoute"
    )
  }

  private func mountPreferredAgentSurfaceIfNeeded(reason: String) {
    guard let provider = route.bridgeProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
      !provider.isEmpty
    else { return }
    appShellRouteLog(
      "ChatConversationController primaryAgentMountAttempt chatId=\(route.chatId) provider=\(provider) reason=\(reason) windowAttached=\(view.window != nil) hasAppeared=\(hasAppeared)")
    mainView.presentPreferredAgentViewNow(provider: provider)
  }

  private func applySurfaceAppearance(
    _ appearance: [String: Any],
    reason: String,
    allowDeferUntilAttached: Bool
  ) {
    if allowDeferUntilAttached, view.window == nil {
      pendingAppearanceForAttachment = appearance
      appShellRouteLog(
        "ChatConversationController deferAppearance chatId=\(route.chatId) reason=\(reason) windowAttached=false")
      return
    }
    pendingAppearanceForAttachment = nil
    let startedAt = CFAbsoluteTimeGetCurrent()
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController setAppearance chatId=\(route.chatId) reason=\(reason)"
    )
    appShellRouteLog(
      "ChatConversationController setAppearanceStart chatId=\(route.chatId) reason=\(reason)")
    mainView.setAppearance(appearance)
    profileView?.setAppearance(appearance)
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    appShellRouteLog(
      "ChatConversationController setAppearanceDone chatId=\(route.chatId) reason=\(reason) durationMs=\(durationMs)")
  }

  private func applyPendingAppearanceAfterAttachment(reason: String) {
    guard view.window != nil, let appearance = pendingAppearanceForAttachment else { return }
    appShellRouteLog(
      "ChatConversationController applyDeferredAppearance chatId=\(route.chatId) reason=\(reason)")
    applySurfaceAppearance(
      appearance,
      reason: "\(reason)-deferred",
      allowDeferUntilAttached: false
    )
  }

  private func applyInputActivation(reason: String) {
    pendingInputActivationForAttachment = false
    // Computer-bridge agents gate the composer behind a paired computer.
    if let provider = route.bridgeProvider, !provider.isEmpty, !bridgeConnectedThisSession {
      applyAgentConnectGate(provider: provider, reason: reason)
      return
    }
    let startedAt = CFAbsoluteTimeGetCurrent()
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController inputActivation chatId=\(route.chatId) reason=\(reason)"
    )
    appShellRouteLog(
      "ChatConversationController inputActivationStart chatId=\(route.chatId) reason=\(reason)")
    mainView.setInputBarEnabled(true)
    mainView.setNativeSendEnabled(true)
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    appShellRouteLog(
      "ChatConversationController inputActivationDone chatId=\(route.chatId) reason=\(reason) durationMs=\(durationMs)")
  }

  // MARK: - Agent bridge connect gate

  /// Hides the composer and shows the Connect panel for an unconnected bridge
  /// agent. The panel polls bridge status and calls back once a computer is online.
  private func applyAgentConnectGate(provider: String, reason: String) {
    // Already known online (warm status cache) → never flash the panel; just reveal
    // the composer. This is the fix for the "we're connected but it shows Connect,
    // then jumps to no panel" flicker on reopen.
    if latestBridgeStatusConnected() {
      handleBridgeConnected()
      verifyWarmBridgeConnection(provider: provider, reason: reason)
      return
    }

    appShellRouteLog(
      "ChatConversationController agentConnectGate chatId=\(route.chatId) provider=\(provider) reason=\(reason)")
    mainView.setInputBarEnabled(false)
    mainView.setNativeSendEnabled(false)

    let model: AgentConnectModel
    if let existing = agentConnectModel {
      model = existing
    } else {
      let created = AgentConnectModel(
        provider: provider,
        displayName: ChatRoute.bridgeDisplayName(for: provider)
      )
      created.onConnected = { [weak self] in
        self?.handleBridgeConnected()
      }
      agentConnectModel = created
      model = created
    }

    // Already showing (or already verifying/scheduled to show) — just keep polling.
    guard agentConnectHost == nil, pendingConnectPanelWork == nil, pendingConnectStatusTask == nil else {
      model.startPolling()
      return
    }
    model.startPolling()

    let chatId = route.chatId
    let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    pendingConnectStatusTask = Task { [weak self, weak model] in
      var status: AgentBridgeStatus?
      if let config = AppSessionConfig.current {
        status = try? await AgentPairingService.status(config: config)
      }
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, let model, !Task.isCancelled else { return }
        self.pendingConnectStatusTask = nil
        let currentProvider = self.route.bridgeProvider?
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased() ?? ""
        guard self.route.chatId == chatId, currentProvider == normalizedProvider else { return }
        if let status {
          model.status = status
          model.selectedRepository = AgentBridgeSelectionStore.ensureValidSelection(from: status.repositories)
        }
        if status?.connected == true || self.latestBridgeStatusConnected() {
          self.handleBridgeConnected()
          return
        }
        guard !self.bridgeConnectedThisSession, self.agentConnectHost == nil else { return }
        self.presentAgentConnectPanel(model: model)
      }
    }
  }

  private func latestBridgeStatusConnected() -> Bool {
    AgentPairingService.lastConnected
      || AgentPairingService.lastStatusSnapshot?.connected == true
      || AgentPairingService.lastStatus?.connected == true
  }

  private func verifyWarmBridgeConnection(provider: String, reason: String) {
    let chatId = route.chatId
    let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    pendingConnectStatusTask?.cancel()
    pendingConnectStatusTask = Task { [weak self] in
      guard let config = AppSessionConfig.current else { return }
      let status = try? await AgentPairingService.status(config: config)
      guard !Task.isCancelled, status?.connected == false else {
        await MainActor.run { self?.pendingConnectStatusTask = nil }
        return
      }
      await MainActor.run {
        guard let self, !Task.isCancelled else { return }
        self.pendingConnectStatusTask = nil
        let currentProvider = self.route.bridgeProvider?
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased() ?? ""
        guard self.route.chatId == chatId, currentProvider == normalizedProvider else { return }
        self.bridgeConnectedThisSession = false
        self.applyAgentConnectGate(provider: provider, reason: "\(reason)-verifiedOffline")
      }
    }
  }

  private func presentAgentConnectPanel(model: AgentConnectModel) {
    guard agentConnectHost == nil else { return }
    let host = UIHostingController(rootView: AgentConnectPanel(model: model))
    host.view.backgroundColor = .clear
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])
    host.didMove(toParent: self)
    agentConnectHost = host
  }

  private func handleBridgeConnected() {
    guard !bridgeConnectedThisSession else { return }
    bridgeConnectedThisSession = true
    pendingConnectStatusTask?.cancel()
    pendingConnectStatusTask = nil
    pendingConnectPanelWork?.cancel()
    pendingConnectPanelWork = nil
    appShellRouteLog(
      "ChatConversationController agentBridgeConnected chatId=\(route.chatId)")
    removeAgentConnectPanel()
    mainView.setInputBarEnabled(true)
    mainView.setNativeSendEnabled(true)
  }

  private func removeAgentConnectPanel() {
    pendingConnectPanelWork?.cancel()
    pendingConnectPanelWork = nil
    pendingConnectStatusTask?.cancel()
    pendingConnectStatusTask = nil
    agentConnectModel?.stopPolling()
    if let host = agentConnectHost {
      host.willMove(toParent: nil)
      host.view.removeFromSuperview()
      host.removeFromParent()
    }
    agentConnectHost = nil
  }

  private func presentBridgeRepositoryPicker(provider: String) {
    let displayName = ChatRoute.bridgeDisplayName(for: provider)
    let root = AgentBridgeRepositoryPickerView(
      provider: provider, displayName: displayName, chatId: route.chatId)
      .preferredColorScheme(isDark ? .dark : .light)
    let host = UIHostingController(rootView: root)
    host.modalPresentationStyle = .pageSheet
    host.view.backgroundColor = .clear
    if let sheet = host.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28
    }
    present(host, animated: true)
  }

  /// Clears any active connect gate (used when the host is reused for another chat).
  private func resetAgentConnectGate() {
    removeAgentConnectPanel()
    agentConnectModel = nil
    bridgeConnectedThisSession = false
  }

  private func applyPendingInputActivationAfterAttachment(reason: String) {
    guard view.window != nil, pendingInputActivationForAttachment else { return }
    applyInputActivation(reason: "\(reason)-deferred")
  }

  private func schedulePostPresentationActivation(reason: String) {
    guard view.window != nil, hasAppeared else { return }
    guard !didRunPostPresentationActivation else {
      openChatChannelIfNeeded(reason: "\(reason)-alreadyActivated")
      return
    }
    let chatId = route.chatId
    postPresentationActivationWorkItem?.cancel()
    appShellRouteLog(
      "ChatConversationController schedulePostPresentationActivation chatId=\(chatId) reason=\(reason) delayMs=\(Int(Self.postPresentationActivationDelay * 1000))")
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.route.chatId == chatId, self.view.window != nil, self.hasAppeared else {
        return
      }
      self.didRunPostPresentationActivation = true
      appShellRouteLog(
        "ChatConversationController postPresentationActivation chatId=\(chatId) reason=\(reason)")
      self.configureEngineBindingIfNeeded(
        reason: "\(reason)-postTransition",
        enableStatusAuthority: false
      )
      self.completeDeferredEngineStateRefreshIfNeeded(chatId: chatId)
      self.openChatChannelIfNeeded(reason: "\(reason)-postTransition")
      AppUIStallWatchdog.shared.updateContext(
        "ChatConversationController postPresentationActivation DONE chatId=\(chatId)"
      )
    }
    postPresentationActivationWorkItem = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.postPresentationActivationDelay,
      execute: work
    )
  }

  private func configureEngineBindingIfNeeded(reason: String, enableStatusAuthority: Bool) {
    if route.skipsServerChannel {
      let bindingKey = [
        "local_saved_messages",
        route.chatId,
        "deferred",
      ].joined(separator: "|")
      guard pendingEngineBinding || engineBindingKey != bindingKey else { return }
      pendingEngineBinding = false
      engineBindingKey = bindingKey
      appShellRouteLog(
        "ChatConversationController engineBindingStart chatId=\(route.chatId) reason=\(reason) statusAuthority=N savedMessages=Y")
      mainView.setEngineChannelBindingEnabled(false)
      mainView.setStatusAuthorityEnabled(false)
      appShellRouteLog(
        "ChatConversationController engineBindingSkipSurface chatId=\(route.chatId) reason=\(reason) savedMessages=Y")
      mainView.setEngineSurfaceId("")
      mainView.setEngineChatId(route.chatId)
      mainView.setEnginePeerUserId("")
      loadEngineBindingUserId(chatId: route.chatId, reason: reason)
      appShellRouteLog(
        "ChatConversationController engineBindingDone chatId=\(route.chatId) reason=\(reason) statusAuthority=N savedMessages=Y")
      return
    }

    let surfaceId = "native_chat_\(route.chatId)"
    let bindingKey = [
      surfaceId,
      route.chatId,
      route.peerUserId ?? "",
      enableStatusAuthority ? "status" : "deferred",
    ].joined(separator: "|")
    guard pendingEngineBinding || engineBindingKey != bindingKey else { return }
    pendingEngineBinding = false
    engineBindingKey = bindingKey
    appShellRouteLog(
      "ChatConversationController engineBindingStart chatId=\(route.chatId) reason=\(reason) statusAuthority=\(enableStatusAuthority ? "Y" : "N")")
    mainView.setEngineChannelBindingEnabled(false)
    mainView.setStatusAuthorityEnabled(false)
    appShellRouteLog(
      "ChatConversationController engineBindingSetSurface chatId=\(route.chatId) reason=\(reason)")
    mainView.setEngineSurfaceId(surfaceId)
    appShellRouteLog(
      "ChatConversationController engineBindingSetChatId chatId=\(route.chatId) reason=\(reason)")
    mainView.setEngineChatId(route.chatId)
    appShellRouteLog(
      "ChatConversationController engineBindingSetPeer chatId=\(route.chatId) reason=\(reason)")
    mainView.setEnginePeerUserId(route.peerUserId ?? "")
    if enableStatusAuthority {
      appShellRouteLog(
        "ChatConversationController engineBindingEnableStatus chatId=\(route.chatId) reason=\(reason)")
      mainView.setStatusAuthorityEnabled(true)
    }
    loadEngineBindingUserId(chatId: route.chatId, reason: reason)
    appShellRouteLog(
      "ChatConversationController engineBindingDone chatId=\(route.chatId) reason=\(reason) statusAuthority=\(enableStatusAuthority ? "Y" : "N")")
  }

  private func loadEngineBindingUserId(chatId: String, reason: String) {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let config = ChatEngineStore.shared.getConfig()
      let myUserId =
        Self.normalizedString(config["myUserId"])
        ?? Self.normalizedString(config["userId"])
      guard let myUserId else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.route.chatId == chatId else { return }
        guard self.engineBindingUserId != myUserId else { return }
        self.engineBindingUserId = myUserId
        AppUIStallWatchdog.shared.updateContext(
          "[AppShellRoute] ChatConversationController engineBindingApplyUserId chatId=\(chatId) reason=\(reason)"
        )
        self.mainView.setEngineMyUserId(myUserId)
        AppUITrace.notice(
          "[AppShellRoute] ChatConversationController engineBindingUserIdApplied chatId=\(chatId) reason=\(reason)"
        )
        AppUIStallWatchdog.shared.updateContext("")
      }
    }
  }

  private func openChatChannelIfNeeded(reason: String) {
    guard openedChatId != route.chatId else { return }
    let chatId = route.chatId
    let peerUserId = route.peerUserId ?? ""
    openedChatId = chatId
    if route.skipsServerChannel {
      openedChatIdUsesEngineChannel = false
      appShellRouteLog(
        "ChatConversationController openChatChannel skipped chatId=\(chatId) reason=\(reason) localSurface=Y")
      return
    }
    openedChatIdUsesEngineChannel = true
    appShellRouteLog(
      "ChatConversationController openChatChannel scheduled chatId=\(chatId) peerUserId=\(peerUserId) reason=\(reason) windowAttached=\(view.window != nil) hasAppeared=\(hasAppeared)")
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let startedAt = CFAbsoluteTimeGetCurrent()
      appShellRouteLog(
        "ChatConversationController openChatChannel backgroundStart chatId=\(chatId) reason=\(reason)")
      let snapshot = ChatEngine.shared.openChatChannel([
        "chatId": chatId,
        "peerUserId": peerUserId,
      ])
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
      appShellRouteLog(
        "ChatConversationController openChatChannel backgroundDone chatId=\(chatId) reason=\(reason) durationMs=\(durationMs)")
      self.appRouteLogOpenResult(chatId: chatId, snapshot: snapshot)
    }
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController openChatChannelIfNeeded DONE chatId=\(chatId)"
    )
  }

  private func closeOpenedChatChannel() {
    guard let openedChatId else { return }
    let usesEngineChannel = openedChatIdUsesEngineChannel
    self.openedChatId = nil
    openedChatIdUsesEngineChannel = false
    guard usesEngineChannel else { return }
    let windowAttachedAtSchedule: Bool?
    if Thread.isMainThread {
      windowAttachedAtSchedule = view.window != nil
    } else {
      windowAttachedAtSchedule = nil
    }
    let windowAttachedLabel = windowAttachedAtSchedule.map { String($0) } ?? "unknown"
    appShellRouteLog(
      "ChatConversationController closeChatChannel scheduled chatId=\(openedChatId) windowAttached=\(windowAttachedLabel) mainThread=\(Thread.isMainThread)")
    DispatchQueue.global(qos: .utility).async {
      let snapshot = ChatEngine.shared.closeChatChannel(["chatId": openedChatId])
      let state = Self.normalizedString(snapshot["state"]) ?? "nil"
      let openCount = snapshot["openChatChannelCount"] as? Int ?? -1
      appShellRouteLog(
        "ChatConversationController closeChatChannel finished chatId=\(openedChatId) state=\(state) openChatCount=\(openCount)")
    }
  }

  private func refreshRows(preferInitialRows: Bool = false) {
    rowsRefreshGeneration &+= 1
    let generation = rowsRefreshGeneration
    let chatId = route.chatId
    let initialRows = route.initialRows
    if preferInitialRows {
      let firstRowID =
        Self.normalizedString(initialRows.first?["id"])
        ?? Self.normalizedString(initialRows.first?["messageId"])
        ?? "nil"
      appShellRouteLog(
        "ChatConversationController refreshRows immediate chatId=\(chatId) rows=\(initialRows.count) source=initial firstRowId=\(firstRowID)")
      let didApply = applyRowsToSurface(
        initialRows,
        chatId: chatId,
        source: "initial",
        firstRowID: firstRowID,
        allowDeferUntilAttached: true
      )
      if didApply {
        deferredEngineRowsReadyChatId = chatId
        completeDeferredEngineStateRefreshIfNeeded(chatId: chatId)
        settleInitialBottomIfNeeded(reason: "initialRows")
      }
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let nativeRows = ChatEngine.shared.getChatRows(["chatId": chatId])
      DispatchQueue.main.async { [weak self] in
        guard let self, self.route.chatId == chatId, self.rowsRefreshGeneration == generation else {
          return
        }
        let rows = nativeRows.isEmpty ? initialRows : nativeRows
        let firstRowID =
          Self.normalizedString(rows.first?["id"])
          ?? Self.normalizedString(rows.first?["messageId"])
          ?? "nil"
        appShellRouteLog(
          "ChatConversationController refreshRows chatId=\(chatId) rows=\(rows.count) nativeRows=\(nativeRows.count) initialRows=\(initialRows.count) source=\(nativeRows.isEmpty ? "initial" : "native") firstRowId=\(firstRowID)")
        let didApply = self.applyRowsToSurface(
          rows,
          chatId: chatId,
          source: nativeRows.isEmpty ? "initial" : "native",
          firstRowID: firstRowID,
          allowDeferUntilAttached: true
        )
        if didApply {
          self.deferredEngineRowsReadyChatId = chatId
          self.completeDeferredEngineStateRefreshIfNeeded(chatId: chatId)
          self.settleInitialBottomIfNeeded(reason: "refreshRows")
          self.logVisualState("afterRefreshRows")
        }
      }
    }
  }

  private func refreshPersistentAgentInboxSummary() {
    guard route.isAgentInboxMode,
      let agentID = route.peerAgentId,
      !agentID.isEmpty,
      let config = AppSessionConfig.current
    else { return }

    Task { [weak self] in
      guard let self else { return }
      do {
        let page = try await AgentInboxAPI.loadPage(
          agentID: agentID,
          config: config,
          limit: 1,
          offset: 0
        )
        let preview = page.items.first.map { item in
          item.body.isEmpty ? item.title : item.body
        }
        await MainActor.run {
          guard self.route.peerAgentId == agentID else { return }
          self.mainView.setPersistentAgentEventInbox(
            count: page.total,
            latestPreview: preview
          )
        }
      } catch {
        // The chat-row fallback remains visible if the persistent request fails.
      }
    }
  }

  @discardableResult
  private func applyRowsToSurface(
    _ rows: [[String: Any]],
    chatId: String,
    source: String,
    firstRowID: String,
    allowDeferUntilAttached: Bool
  ) -> Bool {
    latestProfileRows = rows
    guard route.chatId == chatId else { return false }
    if allowDeferUntilAttached, view.window == nil {
      pendingRowsForAttachment = rows
      pendingRowsForAttachmentChatId = chatId
      pendingRowsForAttachmentSource = source
      appShellRouteLog(
        "ChatConversationController deferRowsUntilAttached chatId=\(chatId) rows=\(rows.count) source=\(source) firstRowId=\(firstRowID) hasAppeared=\(hasAppeared)")
      return false
    }

    let startedAt = CFAbsoluteTimeGetCurrent()
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController setRows chatId=\(chatId) rows=\(rows.count) source=\(source)"
    )
    mainView.setRows(rows)
    lastAppliedRowsToSurfaceCount = rows.count
    if currentPage == .profile {
      profileView?.setRows(rows)
    }
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    appShellRouteLog(
      "ChatConversationController setRowsApplied chatId=\(chatId) rows=\(rows.count) source=\(source) durationMs=\(durationMs) firstRowId=\(firstRowID)")
    return true
  }

  private func applyPendingRowsAfterAttachment(reason: String) {
    guard view.window != nil else { return }
    guard let rows = pendingRowsForAttachment,
      let chatId = pendingRowsForAttachmentChatId,
      chatId == route.chatId
    else { return }
    let source = pendingRowsForAttachmentSource ?? "pending"
    pendingRowsForAttachment = nil
    pendingRowsForAttachmentChatId = nil
    pendingRowsForAttachmentSource = nil
    let firstRowID =
      Self.normalizedString(rows.first?["id"])
      ?? Self.normalizedString(rows.first?["messageId"])
      ?? "nil"
    appShellRouteLog(
      "ChatConversationController applyDeferredRows reason=\(reason) chatId=\(chatId) rows=\(rows.count) source=\(source)")
    let didApply = applyRowsToSurface(
      rows,
      chatId: chatId,
      source: "\(source)-deferred",
      firstRowID: firstRowID,
      allowDeferUntilAttached: false
    )
    if didApply {
      deferredEngineRowsReadyChatId = chatId
      completeDeferredEngineStateRefreshIfNeeded(chatId: chatId)
      logVisualState("afterApplyDeferredRows", force: true)
    }
  }

  private func completeDeferredEngineStateRefreshIfNeeded(chatId: String) {
    guard didRunPostPresentationActivation else { return }
    guard hasAppeared, pendingDeferredEngineStateRefresh, route.chatId == chatId,
      deferredEngineRowsReadyChatId == chatId
    else { return }
    pendingDeferredEngineStateRefresh = false
    deferredEngineRowsReadyChatId = nil
    appShellRouteLog(
      "ChatConversationController completeDeferredEngineState chatId=\(chatId)")
    configureEngineBindingIfNeeded(reason: "completeDeferredEngineState", enableStatusAuthority: false)
    mainView.setDefersEngineStateRefreshes(false)
    mainView.refreshEngineStateAfterDeferredRouteOpen()
    refreshHeaderState()
  }

  private func appRouteLogOpenResult(chatId: String, snapshot: [String: Any]) {
    let state = Self.normalizedString(snapshot["state"]) ?? "nil"
    let openCount = snapshot["openChatChannelCount"] as? Int ?? -1
    let joinedCount = snapshot["nativeJoinedChatCount"] as? Int ?? -1
    let boundSurfaceCount = snapshot["boundSurfaceCount"] as? Int ?? -1
    AppUITrace.notice(
      "[AppShellRoute] ChatConversationController openChatChannelResult chatId=\(chatId) state=\(state) connected=\(snapshot["connected"] as? Bool == true ? "true" : "false") openChatCount=\(openCount) joinedChatCount=\(joinedCount) boundSurfaceCount=\(boundSurfaceCount) keyCount=\(snapshot.count)"
    )
  }

  private func settleInitialBottomIfNeeded(reason: String) {
    guard !didInitialScroll else { return }
    guard view.bounds.width > 0.0, view.bounds.height > 0.0 else { return }
    guard lastAppliedRowsToSurfaceCount > 0 else {
      appShellRouteLog(
        "ChatConversationController deferInitialScroll reason=\(reason) chatId=\(route.chatId) rowsReady=false")
      return
    }
    guard view.window != nil else {
      appShellRouteLog(
        "ChatConversationController deferInitialScroll reason=\(reason) chatId=\(route.chatId) windowAttached=false")
      return
    }
    didInitialScroll = true
    let startedAt = CFAbsoluteTimeGetCurrent()
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController initialScroll chatId=\(route.chatId) reason=\(reason)"
    )
    mainView.layoutIfNeeded()
    mainView.scrollToBottom(animated: false)
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    appShellRouteLog(
      "ChatConversationController initialScrollToBottomCompleted reason=\(reason) chatId=\(route.chatId) durationMs=\(durationMs)")
    logLifecycle("initialScrollToBottom reason=\(reason)")
    logVisualState("afterInitialScroll", force: true)
  }

  private func refreshHeaderState() {
    let route = route
    let handle = Self.profileHandle(for: route)
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let subtitle = Self.headerSubtitle(for: route)
      let isOnline = Self.isOnline(for: route)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.route == route else { return }
        self.mainView.setHeaderSubtitle(subtitle)
        self.mainView.setIsOnline(isOnline)
        self.mainView.setProfileHandle(handle)
        self.profileView?.setHeaderSubtitle(subtitle)
        self.profileView?.setIsOnline(isOnline)
        self.profileView?.setProfileHandle(handle)
      }
    }
  }

  private func refreshRouteOnlyHeaderState() {
    mainView.setHeaderSubtitle(Self.routeOnlyHeaderSubtitle(for: route))
    mainView.setIsOnline(false)
    mainView.setProfileHandle(Self.profileHandle(for: route))
    profileView?.setHeaderSubtitle(Self.routeOnlyHeaderSubtitle(for: route))
    profileView?.setIsOnline(false)
    profileView?.setProfileHandle(Self.profileHandle(for: route))
  }

  private func makeProfileViewIfNeeded() -> ChatProfileMainView {
    if let profileView {
      return profileView
    }

    let nextProfileView = ChatProfileMainView()
    nextProfileView.translatesAutoresizingMaskIntoConstraints = false
    nextProfileView.isHidden = true
    nextProfileView.alpha = 0.0
    nextProfileView.onNativeEvent.handler = { [weak self] payload in
      self?.handleNativeEvent(payload)
    }
    view.addSubview(nextProfileView)
    NSLayoutConstraint.activate([
      nextProfileView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      nextProfileView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      nextProfileView.topAnchor.constraint(equalTo: view.topAnchor),
      nextProfileView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    profileView = nextProfileView
    return nextProfileView
  }

  private func configureProfileView(_ profileView: ChatProfileMainView, rows: [[String: Any]]) {
    let surfaceId = "native_profile_\(route.chatId)"
    profileView.surfaceId = surfaceId
    profileView.setProfileOnly(true)
    profileView.setEngineSurfaceId(surfaceId)
    profileView.setEngineChatId(route.chatId)
    profileView.setEnginePeerUserId(route.peerUserId ?? "")
    if let myUserId = Self.normalizedString(
      ChatEngineStore.shared.getConfig()["myUserId"] ?? ChatEngineStore.shared.getConfig()["userId"]
    ) {
      profileView.setEngineMyUserId(myUserId)
    }
    profileView.setAppearance(Self.resolvedAppearance(isDark: isDark))
    profileView.setHeaderTitle(route.title)
    profileView.setHeaderSubtitle(Self.routeOnlyHeaderSubtitle(for: route))
    profileView.setProfileName(route.title)
    profileView.setBridgeProvider(route.bridgeProvider ?? "")
    profileView.setProfileHandle(Self.profileHandle(for: route))
    profileView.setProfileBio("")
    profileView.setAvatarUri(route.avatarURI)
    profileView.setIsGroupOrChannel(route.isGroup)
    profileView.setRows(rows)
  }

  private func showProfileView(animated: Bool) {
    guard currentPage != .profile else { return }
    currentPage = .profile
    let profileView = makeProfileViewIfNeeded()
    configureProfileView(profileView, rows: latestProfileRows)
    profileView.layer.removeAllAnimations()
    mainView.layer.removeAllAnimations()
    view.bringSubviewToFront(profileView)
    profileView.isHidden = false
    profileView.alpha = 1.0
    let width = max(view.bounds.width, 1.0)
    guard animated, view.window != nil else {
      profileView.transform = .identity
      mainView.transform = .identity
      return
    }
    profileView.transform = CGAffineTransform(translationX: width, y: 0.0)
    UIView.animate(
      withDuration: 0.34,
      delay: 0.0,
      usingSpringWithDamping: 0.9,
      initialSpringVelocity: 0.28,
      options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
    ) {
      profileView.transform = .identity
      self.mainView.transform = CGAffineTransform(translationX: -width * 0.28, y: 0.0)
    } completion: { _ in
      self.mainView.transform = CGAffineTransform(translationX: -width * 0.28, y: 0.0)
    }
  }

  private func hideProfileView(animated: Bool) {
    guard profileView?.isHidden == false else {
      currentPage = .chat
      return
    }
    removeProfileView(animated: animated)
  }

  private func removeProfileView(animated: Bool) {
    guard let profileView else {
      currentPage = .chat
      mainView.transform = .identity
      return
    }
    currentPage = .chat
    profileView.layer.removeAllAnimations()
    mainView.layer.removeAllAnimations()
    let width = max(view.bounds.width, 1.0)
    guard animated, view.window != nil else {
      profileView.transform = .identity
      profileView.alpha = 0.0
      profileView.isHidden = true
      mainView.transform = .identity
      return
    }
    UIView.animate(
      withDuration: 0.32,
      delay: 0.0,
      usingSpringWithDamping: 0.92,
      initialSpringVelocity: 0.24,
      options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
    ) {
      profileView.transform = CGAffineTransform(translationX: width, y: 0.0)
      profileView.alpha = 1.0
      self.mainView.transform = .identity
    } completion: { _ in
      profileView.transform = .identity
      profileView.alpha = 0.0
      profileView.isHidden = true
      self.mainView.transform = .identity
    }
  }

  private var bridgeAgentSurfaceNav: UINavigationController?

  /// Host the agent runtime VC full-screen over the chat surface (its own header + full
  /// bounds — no nesting/clipping). Back returns to the chat surface.
  private func presentBridgeAgentSurface(_ vc: VibeAgentConversationViewController) {
    dismissBridgeAgentSurface()
    bridgeAgentSurfaceVC = vc
    let nav = UINavigationController(rootViewController: vc)
    nav.navigationBar.prefersLargeTitles = false
    bridgeAgentSurfaceNav = nav
    // Back routing: a primary entry (Default view = Agent) is the DM's own page, so Back
    // exits straight to Home; a "See progress" drill-down peels back to the chat surface.
    if vc.isPrimaryAgentSurface {
      vc.onClose = { [weak self] in self?.exitConversationToHome() }
    } else {
      vc.onClose = { [weak self] in self?.dismissBridgeAgentSurface() }
    }
    addChild(nav)
    nav.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(nav.view)
    NSLayoutConstraint.activate([
      nav.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      nav.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      nav.view.topAnchor.constraint(equalTo: view.topAnchor),
      nav.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    nav.didMove(toParent: self)
    // Primary entry = the DM's own page. The Default-view=Agent path now mounts it BEFORE this
    // controller has appeared, so it rides the controller's own push/present transition — one
    // clean page-in, with the opaque agent view covering the chat from the first frame (no chat
    // flash, no second "morph"). Only animate a separate trailing-edge slide when it's added
    // AFTER the controller is already on screen, so a late mount still reads as a push.
    if vc.isPrimaryAgentSurface && hasAppeared {
      view.layoutIfNeeded()
      nav.view.transform = CGAffineTransform(translationX: view.bounds.width, y: 0.0)
      UIView.animate(
        withDuration: 0.3, delay: 0.0,
        options: [.curveEaseOut, .allowUserInteraction]
      ) {
        nav.view.transform = .identity
      }
    }
    // Keep the Connect panel (if the bridge isn't paired yet) on top so the user can still
    // connect; once connected it's removed and the agent surface underneath is revealed.
    if let connectHost = agentConnectHost {
      view.bringSubviewToFront(connectHost.view)
    }
    appShellRouteLog("ChatConversationController presentAgentSurface chatId=\(route.chatId)")
  }

  /// Exit the whole DM to Home — used when the agent surface is the DM's primary entry, so
  /// Back doesn't strand the user on the (never-intended) chat surface. Mirrors the `.chat`
  /// headerBack exit; the agent overlay rides this controller's pop out to Home, then is
  /// detached once the transition settles so a recycled controller starts clean.
  private func exitConversationToHome() {
    if let onClose {
      onClose()
      DispatchQueue.main.async { [weak self] in
        guard let self, self.presentingViewController != nil, !self.isBeingDismissed else {
          return
        }
        self.dismiss(animated: true)
      }
    } else if let navigationController {
      navigationController.popViewController(animated: true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      self?.dismissBridgeAgentSurface()
    }
  }

  /// Remove the isolated agent surface, returning to the chat surface underneath.
  private func dismissBridgeAgentSurface() {
    guard let nav = bridgeAgentSurfaceNav else { return }
    nav.willMove(toParent: nil)
    nav.view.removeFromSuperview()
    nav.removeFromParent()
    bridgeAgentSurfaceNav = nil
    bridgeAgentSurfaceVC = nil
    appShellRouteLog("ChatConversationController dismissAgentSurface chatId=\(route.chatId)")
  }

  private func handleNativeEvent(_ payload: [String: Any]) {
    let type = Self.normalizedString(payload["type"]) ?? ""
    appShellRouteLog(
      "ChatConversationController nativeEvent chatId=\(route.chatId) type=\(type) payloadKeys=\(payload.keys.sorted())")
    switch type {
    case "headerBack":
      switch currentPage {
      case .chat:
        if let onClose {
          appShellRouteLog("ChatConversationController dismissPresented chatId=\(route.chatId)")
          onClose()
          DispatchQueue.main.async { [weak self] in
            guard let self, self.presentingViewController != nil, !self.isBeingDismissed else {
              return
            }
            appShellRouteLog(
              "ChatConversationController fallbackSelfDismiss chatId=\(self.route.chatId)")
            self.dismiss(animated: true)
          }
        } else if let navigationController {
          navigationController.popViewController(animated: true)
        }
      case .profile:
        hideProfileView(animated: true)
      case .agent:
        showProfileView(animated: true)
      }
    case "headerAvatarPressed":
      showProfileView(animated: true)
    case "headerAgentPressed":
      return
    case "agentChatPressed":
      guard
        let agentUserId = Self.normalizedString(
          payload["agentUserId"] ?? payload["agent_user_id"])
      else { return }
      let tappedAgentID = Self.normalizedString(payload["agentId"] ?? payload["agent_id"])
      if agentUserId == route.peerUserId || tappedAgentID == route.peerAgentId {
        return
      }
      let agentName =
        Self.normalizedString(payload["agentName"] ?? payload["agent_name"]) ?? "Agent"
      let agentUsername = Self.normalizedString(
        payload["agentUsername"] ?? payload["agent_username"]
          ?? payload["agentHandle"] ?? payload["agent_handle"])
      Task { @MainActor [weak self] in
        guard let self else { return }
        await openAgentDirectChat(
          from: self,
          agentUserId: agentUserId,
          agentName: agentName,
          agentUsername: agentUsername
        )
      }
    case "agentInboxPressed":
      let inboxRows = mainView.currentEventInboxRows()
      let inboxVC = AgentInboxViewController(
        rows: inboxRows,
        agentTitle: route.title,
        agentID: route.peerAgentId,
        config: AppSessionConfig.current
      )
      let nav = UINavigationController(rootViewController: inboxVC)
      nav.modalPresentationStyle = .pageSheet
      if let sheet = nav.sheetPresentationController {
        sheet.detents = [.large()]
        sheet.prefersGrabberVisible = true
      }
      present(nav, animated: true)
    case "openAgentPanel":
      let payloadProvider =
        Self.normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])
      if let provider = payloadProvider ?? route.bridgeProvider, !provider.isEmpty {
        presentBridgeRepositoryPicker(provider: provider)
      }
    case "agentStopStreaming":
      if let provider = route.bridgeProvider, !provider.isEmpty {
        let result = ChatEngine.shared.sendAgentBridgeControl([
          "chatId": route.chatId,
          "provider": provider,
          "action": "cancel",
        ])
        appShellRouteLog(
          "ChatConversationController bridgeStop chatId=\(route.chatId) provider=\(provider) result=\(result)")
      }
    case "agentToast":
      if let message = Self.normalizedString(payload["message"]) {
        AppToastController.shared.show(message)
      }
    case "headerSearchPressed":
      if currentPage == .profile {
        hideProfileView(animated: true)
	      }
      mainView.openHeaderSearch()
    case "headerAudioCallPressed":
      NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
    case "headerVideoCallPressed":
      NativeCallRouteBridge.startOutgoing(route: route, callType: "video")
    case "headerMenuAction":
      let action = Self.normalizedString(payload["action"]) ?? ""
      if action == "clearChat" {
        presentClearChatOptions()
      }
    case "mainPageChanged":
      if let page = Self.normalizedString(payload["page"]),
        let resolved = ChatConversationPage(rawValue: page)
      {
        currentPage = resolved
      }
    case "inputActionPressed":
      let action = Self.normalizedString(payload["action"]) ?? ""
      switch action {
      case "delete":
        let forEveryone = (payload["forEveryone"] as? Bool) ?? false
        let messageIds = (payload["messageIds"] as? [String]) ?? []
        appShellRouteLog(
          "ChatConversationController delete chatId=\(route.chatId) forEveryone=\(forEveryone) count=\(messageIds.count)")
        for msgId in messageIds {
          _ = ChatEngine.shared.deleteMessage([
            "chatId": route.chatId,
            "messageId": msgId,
            "forEveryone": forEveryone,
          ])
        }
      case "shareInside":
        let messageIds = (payload["messageIds"] as? [String]) ?? []
        appShellRouteLog(
          "ChatConversationController shareInside chatId=\(route.chatId) count=\(messageIds.count)")
        // Present chat selection to pick a target chat for forwarding
        if AppSessionConfig.current != nil {
          let sourceChatId = route.chatId
          struct ShareSheetWrapper: View {
            let onSelect: ([String: Any]) -> Void
            let onDismiss: () -> Void
            @State private var isPresented = false

            var body: some View {
              Color.clear
                .onAppear {
                  isPresented = true
                }
                .sheet(isPresented: $isPresented, onDismiss: {
                  onDismiss()
                }) {
                  ShareChatSelectionView(onSelect: { payload in
                    isPresented = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                      onSelect(payload)
                      onDismiss()
                    }
                  })
                  .chatShareSheetPresentation()
                }
            }
          }

          var shareVC: UIHostingController<ShareSheetWrapper>!
          shareVC = UIHostingController(
            rootView: ShareSheetWrapper(
              onSelect: { [weak self] searchPayload in
                guard let targetChatIds = searchPayload["chatIds"] as? [String] else { return }
                for targetChatId in targetChatIds {
                  for msgId in messageIds {
                    if var row = ChatEngine.shared.getLiveMessageRow([
                      "chatId": sourceChatId,
                      "messageId": msgId,
                    ]) {
                      row["chatId"] = targetChatId
                      row.removeValue(forKey: "messageId")
                      row.removeValue(forKey: "message_id")
                      row.removeValue(forKey: "id")
                      row.removeValue(forKey: "status")
                      row.removeValue(forKey: "replyToId")
                      row.removeValue(forKey: "reply_to_id")
                      _ = ChatEngine.shared.sendMessage(row)
                    }
                  }
                }
                self?.mainView.clearMessageSelection()
              },
              onDismiss: {
                shareVC.dismiss(animated: false)
              }
            )
          )
          shareVC.view.backgroundColor = .clear
          shareVC.modalPresentationStyle = .overFullScreen
          present(shareVC, animated: false)
        }
      default:
        break
      }
    default:
      break
    }
  }

  private func presentClearChatOptions() {
    let presenter = topMostPresenter()
    let canClearForEveryone = route.peerUserId != nil && !route.isGroup && route.chatId != "saved_messages"
    let sheet = UIAlertController(
      title: "Clear Chat",
      message: nil,
      preferredStyle: .actionSheet
    )
    if canClearForEveryone {
      sheet.addAction(
        UIAlertAction(title: "Clear for me and \(route.title)", style: .destructive) {
          [weak self] _ in
          self?.performClearChat(deleteForEveryone: true)
        })
    }
    sheet.addAction(
      UIAlertAction(
        title: canClearForEveryone ? "Clear just for me" : "Clear for me",
        style: .destructive
      ) { [weak self] _ in
        self?.performClearChat(deleteForEveryone: false)
      })
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: view.safeAreaInsets.top + 44.0, width: 1.0, height: 1.0)
      popover.permittedArrowDirections = []
    }
    presenter.present(sheet, animated: true)
  }

  private func topMostPresenter() -> UIViewController {
    var presenter: UIViewController = self
    while let presented = presenter.presentedViewController {
      presenter = presented
    }
    return presenter
  }

  private func performClearChat(deleteForEveryone: Bool) {
    if deleteForEveryone {
      _ = ChatEngine.shared.clearChat([
        "chatId": route.chatId,
        "localOnly": true,
      ])
      mainView.setRows([])
      profileView?.setRows([])
      latestProfileRows = []
      guard let config = AppSessionConfig.current else {
        AppToastController.shared.show("The current session is unavailable.")
        return
      }
      Task { @MainActor in
        do {
          try await ChatHomeEditService.deleteChat(
            chatID: route.chatId,
            config: config,
            deleteForEveryone: true
          )
          AppToastController.shared.show("Chat cleared for both sides.")
        } catch {
          AppToastController.shared.show(error.localizedDescription)
        }
      }
      return
    }

    _ = ChatEngine.shared.clearChat(["chatId": route.chatId])
    mainView.setRows([])
    profileView?.setRows([])
    latestProfileRows = []
    AppToastController.shared.show("Chat cleared.")
  }

  @objc private func handleChatEngineChanged(_ notification: Notification) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleChatEngineChanged(notification)
      }
      return
    }

    if hasAppeared && view.window == nil {
      appShellRouteLog(
        "ChatConversationController engineChanged ignoredDetached chatId=\(route.chatId) reason=\(Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown")")
      return
    }
    if isBeingDismissed {
      appShellRouteLog(
        "ChatConversationController engineChanged ignoredDismissing chatId=\(route.chatId) reason=\(Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown")")
      return
    }
    if isDismantled {
      appShellRouteLog(
        "ChatConversationController engineChanged ignoredDismantled chatId=\(route.chatId) reason=\(Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown")")
      return
    }

    let changedChatId = Self.normalizedString(notification.userInfo?["chatId"])
    let changeReason = Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown"
    if changeReason == "surfaceBindingChanged", changedChatId == nil {
      return
    }
    if route.chatId == "saved_messages", changedChatId == nil {
      return
    }
    guard changedChatId == route.chatId || changedChatId == nil else { return }
    appShellRouteLog(
      "ChatConversationController engineChanged routeChatId=\(route.chatId) changedChatId=\(changedChatId ?? "nil") reason=\(changeReason)")

    if pendingDeferredEngineStateRefresh {
      refreshRouteOnlyHeaderState()
    }

    switch changeReason {
    case "engineError":
      let category = Self.normalizedString(notification.userInfo?["category"])
      if category == "bridgeSendFailed",
        let message = Self.normalizedString(notification.userInfo?["error"])
      {
        AppToastController.shared.show(message)
      }
    case "chatRowsReloaded", "chatMessageInserted", "chatMessageEdited", "chatMessageDeleted",
      "chatMessageChanged", "messageStatusChanged", "presenceChanged", "peerTyping",
      "chatMuteChanged":
      refreshRows()
    default:
      break
    }
  }

  @objc private func handleAgentBridgeSelectionChanged(_ notification: Notification) {
    guard route.bridgeProvider?.isEmpty == false else { return }
    refreshHeaderState()
  }

  private static func isOnline(for route: ChatRoute) -> Bool {
    ChatEngine.shared.isUserOnline(userId: route.peerUserId)
  }

  private static func bridgeHeaderSubtitle(for route: ChatRoute) -> String? {
    guard let provider = route.bridgeProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
      !provider.isEmpty
    else {
      return nil
    }
    let repoName = AgentBridgeSelectionStore.selectedRepository()?.name
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return repoName.isEmpty ? "Pick repository" : repoName
  }

  private static func headerSubtitle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Saved Messages"
    }
    if ChatEngine.shared.isTyping(["chatId": route.chatId]) {
      if route.bridgeProvider?.isEmpty == false {
        return "Running task"
      }
      return "typing..."
    }
    if let bridgeSubtitle = bridgeHeaderSubtitle(for: route) {
      return bridgeSubtitle
    }
    if isOnline(for: route) {
      return "online"
    }
    if route.isGroup {
      return "group"
    }
    if let lastSeen = ChatEngine.shared.lastSeenTimestampMs(userId: route.peerUserId),
      let label = lastSeenLabel(from: lastSeen)
    {
      return label
    }
    return route.peerUserId == nil ? "" : "last seen recently"
  }

  private static func routeOnlyHeaderSubtitle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Saved Messages"
    }
    if let bridgeSubtitle = bridgeHeaderSubtitle(for: route) {
      return bridgeSubtitle
    }
    if route.isGroup {
      return "group"
    }
    return route.peerUserId == nil ? "" : "last seen recently"
  }

  private func logLifecycle(_ event: String) {
    let navCount = navigationController?.viewControllers.count ?? 0
    let navTypes =
      navigationController?.viewControllers.map { String(describing: type(of: $0)) }
      .joined(separator: " > ") ?? "nil"
    let rootType = view.window?.rootViewController.map { String(describing: type(of: $0)) } ?? "nil"
    let parentType = parent.map { String(describing: type(of: $0)) } ?? "nil"
    let presentedType = presentingViewController.map { String(describing: type(of: $0)) } ?? "nil"
    appShellRouteLog(
      "ChatConversationController \(event) chatId=\(route.chatId) navCount=\(navCount) nav=\(navTypes) parent=\(parentType) root=\(rootType) presentedBy=\(presentedType)")
  }

  private func logVisualState(_ event: String, force: Bool = false) {
    let viewFrame = NSCoder.string(for: view.frame)
    let viewBounds = NSCoder.string(for: view.bounds)
    let mainFrame = NSCoder.string(for: mainView.frame)
    let mainBounds = NSCoder.string(for: mainView.bounds)
    let windowBounds = view.window.map { NSCoder.string(for: $0.bounds) } ?? "nil"
    let safeInsets = NSCoder.string(for: view.safeAreaInsets)
    let signature =
      "\(viewFrame)|\(viewBounds)|\(mainFrame)|\(mainBounds)|\(windowBounds)|\(view.window != nil)|\(view.isHidden)|\(view.alpha)|\(mainView.isHidden)|\(mainView.alpha)"
    if !force, signature == lastLayoutSignature {
      return
    }
    lastLayoutSignature = signature
    appShellRouteLog(
      "ChatConversationController \(event) chatId=\(route.chatId) viewFrame=\(viewFrame) viewBounds=\(viewBounds) mainFrame=\(mainFrame) mainBounds=\(mainBounds) windowBounds=\(windowBounds) safeInsets=\(safeInsets) hidden=\(view.isHidden) alpha=\(view.alpha) mainHidden=\(mainView.isHidden) mainAlpha=\(mainView.alpha)")
  }

  private static func profileHandle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Personal notes and media"
    }
    if let peerUserId = normalizedString(route.peerUserId) {
      return peerUserId
    }
    return route.isGroup ? "Group chat" : ""
  }

  private static func lastSeenLabel(from timestampMs: Int64) -> String? {
    guard timestampMs > 0 else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    let relative = formatter.localizedString(for: date, relativeTo: Date())
    let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return "last seen \(trimmed)"
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func backgroundColor(isDark: Bool) -> UIColor {
    isDark
      ? UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
      : UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
  }

  private static func resolvedAppearance(isDark: Bool) -> [String: Any] {
    [
      "theme": isDark ? "dark" : "light",
      "backgroundMode": "gradient",
      "wallpaperOpacity": 1.0,
      "nativeThemeId": AppThemePlateController.currentOption.rawValue,
      "nativeThemeIsDark": isDark,
    ]
  }
}

private struct ChatHomeRowView: View {
  let row: ChatHomeListRow
  let palette: AppThemePalette

  var body: some View {
    HStack(spacing: 14) {
      ChatAvatarView(row: row, palette: palette)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(row.title)
            .font(.system(size: 17, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(palette.text)

          if row.isGoldTier {
            ChatHomeTierBadgeView(label: "Gold")
          }

          if row.isTyping {
            Text("Typing…")
              .font(.caption)
              .foregroundStyle(palette.secondaryText)
              .lineLimit(1)
          }

          Spacer(minLength: 8)

          if !row.timeLabel.isEmpty {
            Text(row.timeLabel)
              .font(.caption)
              .foregroundStyle(palette.secondaryText)
          }
        }

        HStack(spacing: 8) {
          Text(row.preview.isEmpty ? "No messages yet" : row.preview)
            .font(.subheadline)
            .foregroundStyle(palette.secondaryText)
            .lineLimit(2)

          Spacer(minLength: 8)

          if row.unreadCount > 0 {
            Text("\(row.unreadCount)")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(palette.buttonText)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Capsule(style: .continuous).fill(palette.accent))
          }
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(palette.card)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(palette.border, lineWidth: 1)
    )
  }
}

private struct ChatHomeTierBadgeView: View {
  let label: String

  var body: some View {
    Image(systemName: "checkmark.seal.fill")
      .font(.system(size: 14))
      .symbolRenderingMode(.palette)
      .foregroundStyle(Color.primary, Color(red: 1.0, green: 0.78, blue: 0.28))
  }
}

private struct ChatAvatarView: View {
  let row: ChatHomeListRow
  let palette: AppThemePalette
  @Environment(\.colorScheme) private var colorScheme
  @State private var avatarImage: UIImage?
  @State private var avatarImageURI: String?

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      avatarContent
        .frame(width: 54, height: 54)
        .clipShape(Circle())

      if row.isOnline {
        Circle()
          .fill(palette.success)
          .frame(width: 12, height: 12)
          .overlay(
            Circle()
              .stroke(palette.card, lineWidth: 2)
          )
      }
    }
  }

  @ViewBuilder
  private var avatarContent: some View {
    ZStack {
      fallbackAvatar
      if avatarImageURI == normalizedAvatarURI(row.avatarUri), let avatarImage {
        Image(uiImage: avatarImage)
          .resizable()
          .scaledToFill()
      }
    }
    .task(id: row.avatarUri ?? "") {
      await loadAvatarImage(row.avatarUri)
    }
  }

  @ViewBuilder
  private var fallbackAvatar: some View {
    let gradientColors = rowAvatarGradientColors(row: row, palette: palette)
    Circle()
      .fill(
        LinearGradient(
          colors: gradientColors,
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .overlay(
        Group {
          if row.isSavedMessages {
            Image(systemName: "bookmark.fill")
              .font(.system(size: 20, weight: .semibold))
          } else {
            Text(row.avatarFallback)
              .font(.system(size: 20, weight: .bold))
          }
        }
        .foregroundStyle(palette.buttonText)
      )
  }


  private func rowAvatarGradientColors(row: ChatHomeListRow, palette: AppThemePalette) -> [Color] {
    if !row.isSavedMessages {
      let colors = ChatProfileAppearanceStore.avatarColors(
        title: row.title,
        peerUserId: row.peerUserId,
        chatId: row.chatId
      )
      return [Color(uiColor: colors.0), Color(uiColor: colors.1)]
    }

    let startRaw = colorScheme == .dark
      ? (row.avatarGradientStartDark ?? row.avatarGradientStartLight)
      : (row.avatarGradientStartLight ?? row.avatarGradientStartDark)
    let endRaw = colorScheme == .dark
      ? (row.avatarGradientEndDark ?? row.avatarGradientEndLight)
      : (row.avatarGradientEndLight ?? row.avatarGradientEndDark)
    if let startRaw, let endRaw,
      let start = Color(hexString: startRaw),
      let end = Color(hexString: endRaw)
    {
      return [start, end]
    }
    return [palette.accent.opacity(0.9), palette.button.opacity(0.72)]
  }

  private func normalizedAvatarURI(_ rawValue: String?) -> String? {
    let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  @MainActor
  private func loadAvatarImage(_ rawValue: String?) async {
    let normalized = normalizedAvatarURI(rawValue)
    if avatarImageURI != normalized {
      avatarImageURI = normalized
      avatarImage = normalized.flatMap { ChatAvatarImageStore.cached(for: $0) }
    }
    guard let normalized else {
      avatarImage = nil
      return
    }
    if let cached = ChatAvatarImageStore.cached(for: normalized) {
      avatarImage = cached
      return
    }
    let loaded = await ChatAvatarImageStore.load(from: normalized)
    guard !Task.isCancelled, avatarImageURI == normalized else { return }
    if let loaded {
      avatarImage = loaded
    }
  }
}

struct AppChatNavigationHeaderView: View {
  let route: ChatRoute
  let palette: AppThemePalette

  private var subtitle: String {
    if route.chatId == "saved_messages" {
      return "Saved Messages"
    }
    if route.isGroup {
      return "group"
    }
    return route.peerUserId == nil ? "" : "last seen recently"
  }

  var body: some View {
    GlassEffectContainer(spacing: 0.0) {
      headerContent
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(width: 172, height: 44)
        .glassEffect(.regular.interactive(true), in: .capsule)
    }
      .frame(width: 172, height: 44)
      .transaction { transaction in
        transaction.disablesAnimations = true
      }
  }

  private var headerContent: some View {
    VStack(alignment: .center, spacing: 0) {
      Text(route.title.isEmpty ? "Chat" : route.title)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(palette.text)
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .truncationMode(.tail)

      if !subtitle.isEmpty {
        Text(subtitle)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(palette.secondaryText)
          .multilineTextAlignment(.center)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
  }
}

struct AppChatNavigationBackButton: View {
  let unreadCount: Int
  let palette: AppThemePalette
  let action: () -> Void

  private var displayedUnreadCount: Int {
    min(max(0, unreadCount), 99)
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: "chevron.left")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(palette.text)
        .frame(width: 36, height: 44, alignment: .center)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .transaction { transaction in
      transaction.disablesAnimations = true
    }
    .accessibilityLabel(
      displayedUnreadCount > 0 ? "Back, \(unreadCount) unread messages" : "Back"
    )
  }
}

struct AppChatNavigationAvatarButton: View {
  let route: ChatRoute
  let palette: AppThemePalette
  let action: () -> Void
  @Environment(\.colorScheme) private var colorScheme
  @State private var avatarImage: UIImage?
  @State private var avatarImageURI: String?

  private var fallbackText: String {
    let trimmed = route.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "U" : String(trimmed.prefix(1)).uppercased()
  }

  var body: some View {
    Button {
      guard route.chatId != "saved_messages" else { return }
      action()
    } label: {
      ZStack {
        avatarContent
          .frame(width: 30, height: 30)
          .clipShape(Circle())
          .overlay(Circle().stroke(palette.secondaryText.opacity(0.16), lineWidth: 0.5))
      }
        .frame(width: 36, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(route.chatId == "saved_messages")
    .transaction { transaction in
      transaction.disablesAnimations = true
    }
    .accessibilityLabel(route.chatId == "saved_messages" ? "Saved Messages" : "Open profile")
  }

  @ViewBuilder
  private var avatarContent: some View {
    if route.chatId == "saved_messages" {
      ZStack {
        LinearGradient(
          colors: [
            Color(red: 43 / 255, green: 165 / 255, blue: 181 / 255),
            Color(red: 0 / 255, green: 122 / 255, blue: 124 / 255),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        Image(systemName: "bookmark.fill")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
      }
    } else {
      ZStack {
        fallbackAvatar
        if avatarImageURI == normalizedAvatarURI(route.avatarURI), let avatarImage {
          Image(uiImage: avatarImage)
            .resizable()
            .scaledToFill()
        }
      }
      .task(id: route.avatarURI ?? "") {
        await loadAvatarImage(route.avatarURI)
      }
    }
  }
    @ViewBuilder
    private var fallbackAvatar: some View {
      let colors = routeAvatarGradientColors(route: route)
      ZStack {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        Text(fallbackText)
          .font(.system(size: 16, weight: .bold))
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .foregroundStyle(.white)
      }
    }

  private func routeAvatarGradientColors(route: ChatRoute) -> [Color] {
    let colors = ChatProfileAppearanceStore.avatarColors(
      title: route.title,
      peerUserId: route.peerUserId,
      chatId: route.chatId
    )
    return [Color(uiColor: colors.0), Color(uiColor: colors.1)]
  }

  private func normalizedAvatarURI(_ rawValue: String?) -> String? {
    let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  @MainActor
  private func loadAvatarImage(_ rawValue: String?) async {
    let normalized = normalizedAvatarURI(rawValue)
    if avatarImageURI != normalized {
      avatarImageURI = normalized
      avatarImage = normalized.flatMap { ChatAvatarImageStore.cached(for: $0) }
    }
    guard let normalized else {
      avatarImage = nil
      return
    }
    if let cached = ChatAvatarImageStore.cached(for: normalized) {
      avatarImage = cached
      return
    }
    let loaded = await ChatAvatarImageStore.load(from: normalized)
    guard !Task.isCancelled, avatarImageURI == normalized else { return }
    if let loaded {
      avatarImage = loaded
    }
  }
}

private extension Color {
  init?(hexString: String) {
    var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
    self.init(
      red: Double((value >> 16) & 0xFF) / 255.0,
      green: Double((value >> 8) & 0xFF) / 255.0,
      blue: Double(value & 0xFF) / 255.0
    )
  }
}

private enum AppHomeHeaderState {
  case ready
  case waitingForNetwork

  var title: String {
    switch self {
    case .ready:
      return "Chats"
    case .waitingForNetwork:
      return "Waiting for Network"
    }
  }

  var showsProgress: Bool {
    false
  }
}

private struct AppHomeStatusHeaderView: View {
  let state: AppHomeHeaderState
  let palette: AppThemePalette

  var body: some View {
    HStack(spacing: 6) {
      if state.showsProgress {
        ProgressView()
          .controlSize(.small)
          .tint(palette.secondaryText)
      }

      Text(state.title)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(palette.text)
    }
  }
}

private struct AppShellEmptyStateView: View {
  let icon: String
  let title: String
  let message: String
  let buttonTitle: String?
  let palette: AppThemePalette
  let action: (() -> Void)?

  var body: some View {
    VStack(spacing: 18) {
      if icon.hasPrefix("<?xml") || icon.hasPrefix("<svg") {
        AppAnimatedSVGView(svgString: icon)
          .frame(width: 120, height: 120)
      } else {
        Image(systemName: icon)
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(palette.accent)
      }

      VStack(spacing: 8) {
        Text(title)
          .font(.system(size: 24, weight: .bold))
          .foregroundStyle(palette.text)

        Text(message)
          .font(.system(size: 15))
          .foregroundStyle(palette.secondaryText)
          .multilineTextAlignment(.center)
      }

      if let buttonTitle, let action {
        Button(buttonTitle, action: action)
          .buttonStyle(AppPrimaryCapsuleButtonStyle(palette: palette))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 30)
  }
}

private struct AppPrimaryCapsuleButtonStyle: ButtonStyle {
  let palette: AppThemePalette

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 16, weight: .semibold))
      .foregroundStyle(palette.buttonText)
      .padding(.horizontal, 22)
      .frame(height: 48)
      .background(
        Capsule(style: .continuous)
          .fill(configuration.isPressed ? palette.button.opacity(0.82) : palette.button)
      )
      .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

private struct AppToastBanner: View {
  let message: String
  let palette: AppThemePalette

  var body: some View {
    Text(message)
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(palette.text)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity)
      .background(
        Capsule(style: .continuous)
          .fill(palette.card)
      )
      .overlay(
        Capsule(style: .continuous)
          .stroke(palette.border, lineWidth: 1)
      )
      .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
  }
}

private struct ContactSearchView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  let config: AppSessionConfig
  let homeRows: [ChatHomeListRow]
  let onResult: ([String: Any]) -> Void
  @State private var query = ""
  @State private var results: [ContactSearchUser] = []
  @State private var savedUserIDs = Set<String>()
  @State private var isLoading = false
  @State private var hasSearched = false
  @State private var statusText = ""
  @State private var searchTask: Task<Void, Never>?
  @State private var isSearchPresented = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    contactList
      .listStyle(.plain)
      .background(palette.background.ignoresSafeArea())
      .navigationTitle("New Message")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(
        text: $query,
        isPresented: $isSearchPresented,
        placement: .navigationBarDrawer(displayMode: .automatic),
        prompt: "Username, phone, or ID"
      )
      .onChange(of: query) { _, _ in
        scheduleSearch(immediate: false)
      }
      .onDisappear { searchTask?.cancel() }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            onResult(["action": "cancel"])
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
        }
      }
  }

  private var contactList: some View {
    List {
      actionSection
      contentSection
    }
  }

  private var actionSection: some View {
    Section {
      ContactSearchActionRow(
        title: "New Group",
        systemImage: "person.2",
        palette: palette
      ) {
        onResult(["action": "newGroup"])
        dismiss()
      }

      ContactSearchActionRow(
        title: "New Contact",
        systemImage: "person.badge.plus",
        palette: palette
      ) {
        isSearchPresented = true
      }

      ContactSearchActionRow(
        title: "New Channel",
        systemImage: "megaphone",
        palette: palette
      ) {
        onResult(["action": "newChannel"])
        dismiss()
      }
    }
    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    .listRowBackground(Color.clear)
    .listRowSeparatorTint(palette.border)
  }



  @ViewBuilder
  private var contentSection: some View {
    if !results.isEmpty {
      groupedUsersSection(users: results)
    } else if query.isEmpty {
      groupedUsersSection(users: homeRows.map(contactUser(for:)))
    } else {
      statusSection
    }
  }

  private func groupedUsersSection(users: [ContactSearchUser]) -> some View {
    var uniqueUsers: [ContactSearchUser] = []
    var seenIDs = Set<String>()
    for user in users {
      if !seenIDs.contains(user.userID) {
        seenIDs.insert(user.userID)
        uniqueUsers.append(user)
      }
    }
    let grouped = Dictionary(grouping: uniqueUsers) { user in
      String(user.username.prefix(1)).uppercased()
    }
    let sortedKeys = grouped.keys.sorted()

    return ForEach(sortedKeys, id: \.self) { letter in
      Section(letter) {
        ForEach(grouped[letter]!) { user in
          ContactSearchResultRow(
            user: user,
            isSaved: savedUserIDs.contains(user.userID),
            palette: palette
          )
          .contentShape(Rectangle())
          .onTapGesture { open(user, action: "chat") }
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
              open(user, action: "call")
            } label: {
              Label("Call", systemImage: "phone.fill")
            }
            .tint(.green)

            if !savedUserIDs.contains(user.userID) {
              Button {
                savedUserIDs.insert(user.userID)
                onResult(["action": "saveContact", "user": user.payload])
              } label: {
                Label("Add", systemImage: "person.badge.plus")
              }
              .tint(palette.accent)
            }
          }
        }
      }
    }
  }

  private var statusSection: some View {
    Section {
      ContactSearchStatusView(
        isLoading: isLoading,
        hasSearched: hasSearched,
        message: statusText,
        palette: palette
      )
      .frame(maxWidth: .infinity)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
    }
  }



  private func contactUser(for row: ChatHomeListRow) -> ContactSearchUser {
    ContactSearchUser(payload: [
      "userId": row.chatId,
      "username": row.title,
      "displayName": row.title,
      "profileImage": row.avatarUri ?? "",
      "isAgent": row.isAgentFriend,
      "agentId": row.peerAgentId ?? "",
      "tier": row.peerTier ?? "",
    ])!
  }

  private func clearSearch() {
    query = ""
    results = []
    hasSearched = false
    isSearchPresented = true
  }

  private func open(_ user: ContactSearchUser, action: String) {
    onResult(["action": action, "user": user.payload])
    dismiss()
  }

  /// Debounced live search. Typing reschedules a 350ms-delayed query; submitting
  /// runs immediately. A single in-flight task is kept so results never race.
  private func scheduleSearch(immediate: Bool) {
    searchTask?.cancel()
    let queryValue = trimmedQuery
    guard !queryValue.isEmpty else {
      results = []
      hasSearched = false
      statusText = ""
      isLoading = false
      return
    }

    searchTask = Task { @MainActor in
      if !immediate {
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }
      }
      await performSearch(for: queryValue)
    }
  }

  @MainActor
  private func performSearch(for queryValue: String) async {
    isLoading = true
    defer { isLoading = false }

    do {
      let found = try await ContactSearchService.search(config: config, query: queryValue)
      if Task.isCancelled { return }
      results = found
      hasSearched = true
      statusText = found.isEmpty ? "No people found for “\(queryValue)”." : ""
    } catch {
      if Task.isCancelled { return }
      results = []
      hasSearched = true
      statusText = error.localizedDescription
    }
  }
}

/// Compact existing-chat row for the Home search drawer ("Chats" section).
private struct HomeSearchChatRow: View {
  let row: ChatHomeListRow
  let palette: AppThemePalette

  var body: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(palette.background)
        .frame(width: 44, height: 44)
        .overlay {
          Text(String(row.title.prefix(1)).uppercased())
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(palette.accent)
        }

      VStack(alignment: .leading, spacing: 2) {
        Text(row.title)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(palette.text)
          .lineLimit(1)
        Text(row.preview)
          .font(.footnote)
          .foregroundStyle(palette.secondaryText)
          .lineLimit(1)
      }

      Spacer(minLength: 8)
      Image(systemName: "chevron.right")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(palette.secondaryText.opacity(0.6))
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}

struct ContactSearchResultRow: View {
  let user: ContactSearchUser
  let isSaved: Bool
  let palette: AppThemePalette

  var body: some View {
    HStack(spacing: 12) {
      if let profileImage = user.profileImage, let url = URL(string: profileImage) {
        AsyncImage(url: url) { phase in
          if let image = phase.image {
            image.resizable().scaledToFill()
          } else {
            fallbackAvatar
          }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
      } else {
        fallbackAvatar
      }

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(user.username)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(palette.text)
          if user.isGoldTier {
            ChatHomeTierBadgeView(label: "Gold")
          }
        }
        .lineLimit(1)

        let lastSeenText: String = {
          if user.isAgent {
            return "Open and start session"
          }
          return ChatEngine.shared.lastSeenTimestampMs(userId: user.userID).flatMap { timestamp -> String? in
            guard timestamp > 0 else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let relative = formatter.localizedString(for: date, relativeTo: Date())
            let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "last seen \(trimmed)"
          } ?? "last seen recently"
        }()

        Text(lastSeenText)
          .font(.footnote)
          .foregroundStyle(palette.secondaryText)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      if isSaved {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(palette.accent)
      }

      Image(systemName: "chevron.right")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(palette.secondaryText.opacity(0.6))
    }
    .padding(.vertical, 4)
    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    .listRowBackground(Color.clear)
  }

  private var fallbackAvatar: some View {
    let colors = ChatProfileAppearanceStore.avatarColors(
      title: user.username,
      peerUserId: user.userID,
      chatId: nil
    )
    return Circle()
      .fill(
        LinearGradient(
          colors: [Color(uiColor: colors.0), Color(uiColor: colors.1)],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .frame(width: 44, height: 44)
      .overlay {
        Text(String(user.username.prefix(1)).uppercased())
          .font(.system(size: 18, weight: .bold))
          .foregroundStyle(.white)
      }
  }
}

private struct ContactSearchActionRow: View {
  let title: String
  let systemImage: String
  let palette: AppThemePalette
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 16) {
        Image(systemName: systemImage)
          .font(.system(size: 20, weight: .regular))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(palette.accent)
          .frame(width: 32, height: 32)

        Text(title)
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(palette.accent)
          .lineLimit(1)
          .minimumScaleFactor(0.82)

        Spacer(minLength: 8)
      }
      .padding(.vertical, 4)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct ContactSearchStatusView: View {
  let isLoading: Bool
  let hasSearched: Bool
  let message: String
  let palette: AppThemePalette

  var body: some View {
    VStack(spacing: 12) {
      if isLoading {
        ProgressView()
          .tint(palette.secondaryText)
        Text("Searching…")
          .font(.footnote)
          .foregroundStyle(palette.secondaryText)
      } else {
        Image(systemName: hasSearched ? "person.fill.questionmark" : "magnifyingglass")
          .font(.system(size: 30, weight: .regular))
          .foregroundStyle(palette.secondaryText.opacity(0.7))
        Text(displayMessage)
          .font(.footnote)
          .multilineTextAlignment(.center)
          .foregroundStyle(palette.secondaryText)
      }
    }
    .padding(.vertical, 36)
  }

  private var displayMessage: String {
    if !message.isEmpty { return message }
    return hasSearched
      ? "No people found."
      : "Find people by username, phone number, or user ID to start a new chat."
  }
}

struct ContactSearchUser: Identifiable, Hashable, Equatable {
  static func == (lhs: ContactSearchUser, rhs: ContactSearchUser) -> Bool {
    lhs.userID == rhs.userID
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(userID)
  }
  let userID: String
  let username: String
  let handle: String?
  let phoneNumber: String?
  let profileImage: String?
  let publicKey: String?
  let tier: String?
  /// Server `isAgent` flag — true for Claude/Codex (and any other agent shadow user).
  let isAgent: Bool
  /// Server `agentId` — the attached agent's id when `isAgent` is true.
  let agentId: String?

  var id: String { userID }

  var isGoldTier: Bool {
    tier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gold"
  }

  /// `"claude"` / `"codex"` when this search result is a computer-bridge agent.
  var bridgeProvider: String? {
    ChatRoute.resolveBridgeProvider(
      peerUserId: userID,
      name: handle ?? username,
      isAgent: isAgent,
      agentId: agentId
    )
  }

  /// `peerAgentId` to bind for engine routing. For a real agent it's the agent id.
  /// For a bridge agent (Claude/Codex, which have no Agent record) it's the shadow
  /// user id — a non-empty value makes the engine send the message in cleartext
  /// (the server resolves the bridge worker from the DM participant) instead of
  /// E2E-encrypting to the agent's placeholder key, which would fail.
  var bridgeAgentRouteId: String? {
    if bridgeProvider != nil { return userID }
    return agentId
  }

  var subtitle: String {
    if let phoneNumber { return phoneNumber }
    if let handle, !handle.isEmpty, !Self.looksLikeUUID(handle), handle.localizedCaseInsensitiveCompare(username) != .orderedSame {
      return "@\(handle.trimmingCharacters(in: CharacterSet(charactersIn: "@")))"
    }
    return "User is in Vibegram"
  }

  var payload: [String: Any] {
    var value: [String: Any] = [
      "userId": userID,
      "id": userID,
      "username": username,
      "displayName": username,
    ]
    if let handle { value["handle"] = handle }
    if let phoneNumber { value["phoneNumber"] = phoneNumber }
    if let profileImage { value["profileImage"] = profileImage }
    if let publicKey { value["publicKey"] = publicKey }
    if let tier { value["tier"] = tier }
    if isAgent { value["isAgent"] = true }
    if let agentId { value["agentId"] = agentId }
    return value
  }

  init?(payload: [String: Any]) {
    guard let userID = Self.normalizedString(payload["userId"] ?? payload["id"]) else {
      return nil
    }

    self.userID = userID
    let rawHandle = Self.normalizedString(payload["username"] ?? payload["handle"])
    let rawDisplayName =
      Self.normalizedString(
        payload["displayName"] ?? payload["display_name"] ?? payload["fullName"] ?? payload["full_name"]
          ?? payload["name"])
      ?? rawHandle
    self.username =
      rawDisplayName.flatMap { Self.looksLikeUUID($0) ? nil : $0 }
      ?? rawHandle.flatMap { Self.looksLikeUUID($0) ? nil : $0 }
      ?? "Vibegram User"
    self.handle = rawHandle
    self.phoneNumber = Self.normalizedString(payload["phoneNumber"] ?? payload["phone_number"] ?? payload["phone"])
    self.profileImage = Self.normalizedString(
      payload["profileImage"] ?? payload["profile_image"] ?? payload["avatarUrl"] ?? payload["avatar_url"])
    self.publicKey = Self.normalizedString(
      payload["publicKey"] ?? payload["public_key"] ?? payload["friendKey"] ?? payload["friendPublicKey"])
    self.tier = Self.normalizedString(
      payload["tier"] ?? payload["friendTier"] ?? payload["friend_tier"] ?? payload["peerTier"]
        ?? payload["peer_tier"] ?? payload["badge"] ?? payload["badgeTier"] ?? payload["badge_tier"])
    self.isAgent = Self.boolValue(payload["isAgent"] ?? payload["is_agent"])
    self.agentId = Self.normalizedString(
      payload["agentId"] ?? payload["agent_id"] ?? payload["friendAgentId"] ?? payload["friend_agent_id"])
  }

  private static func boolValue(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String { return ["true", "1", "yes"].contains(value.lowercased()) }
    return false
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func looksLikeUUID(_ value: String) -> Bool {
    UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
  }
}

private enum AppSessionRefreshError: LocalizedError {
  case missingSecret

  var errorDescription: String? {
    switch self {
    case .missingSecret:
      return "Session expired. Sign in again."
    }
  }
}

private enum AppSessionRefreshService {
  static func refresh(config: AppSessionConfig) async throws -> AppSessionConfig {
    let rawSecret = SecureKeyStore.shared.retrieveSecret(key: "loginSecret")
    guard
      let secret = rawSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
      !secret.isEmpty
    else {
      throw AppSessionRefreshError.missingSecret
    }

    let result = try await NativeAuthService.signIn(
      secret: secret,
      apiBaseURLString: config.apiBaseURLString,
      transportMode: config.transportMode
    )
    AppSessionConfig.store(result.config)
    _ = SecureKeyStore.shared.storeSecret(key: "loginSecret", value: secret)
    return result.config
  }
}

private func appShellServerErrorMessage(
  statusCode: Int,
  body: String,
  fallback: String
) -> String {
  if
    let data = body.data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let message = (object["message"] ?? object["error"] ?? object["reason"]) as? String
  {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return statusCode == 401 ? trimmed : "\(fallback) (\(statusCode)): \(trimmed)"
    }
  }

  let trimmed = appShellSanitizedServerBody(body)
  return trimmed.isEmpty ? "\(fallback) (\(statusCode))." : "\(fallback) (\(statusCode)): \(trimmed)"
}

private func appShellSanitizedServerBody(_ body: String) -> String {
  let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { return "" }
  let lowered = trimmed.lowercased()
  if lowered.hasPrefix("<!doctype") || lowered.hasPrefix("<html") || lowered.contains("<body") {
    return ""
  }
  return String(trimmed.prefix(180))
}

enum ContactSearchService {
  static func search(config: AppSessionConfig, query: String) async throws -> [ContactSearchUser] {
    let activeConfig = AppSessionConfig.current ?? config
    do {
      return try await performSearch(config: activeConfig, query: query)
    } catch let error as ContactSearchServiceError {
      guard error.isSessionExpired else {
        throw error
      }
      let refreshedConfig = try await AppSessionRefreshService.refresh(config: activeConfig)
      return try await performSearch(config: refreshedConfig, query: query)
    }
  }

  private static func performSearch(config: AppSessionConfig, query: String) async throws -> [ContactSearchUser] {
    guard let url = buildSearchURL(apiBaseURLString: config.apiBaseURLString, query: query) else {
      throw ContactSearchServiceError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 14
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ContactSearchServiceError.invalidResponse
    }

    if httpResponse.statusCode == 404 {
      return []
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw ContactSearchServiceError.http(httpResponse.statusCode, body)
    }

    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return parseUsers(from: object, excluding: config.userID)
  }

  private static func buildSearchURL(apiBaseURLString: String, query: String) -> URL? {
    var base = apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    guard !base.isEmpty else { return nil }

    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    let endpoint: String
    switch queryKind(for: query) {
    case .userID:
      let encodedID = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
      endpoint = "/user/\(encodedID)"
    case .phone:
      let encodedPhone =
        query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
      endpoint = "/user/phone/\(encodedPhone)"
    case .username:
      let normalized =
        query.hasPrefix("@") ? String(query.dropFirst()) : query
      let encodedName =
        normalized.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        ?? normalized.lowercased()
      endpoint = "/user/name/\(encodedName)"
    }

    return URL(string: pathBase + endpoint)
  }

  private static func parseUsers(from value: Any, excluding currentUserID: String) -> [ContactSearchUser] {
    let rawEntries: [[String: Any]]
    if let array = value as? [[String: Any]] {
      rawEntries = array
    } else if let dictionary = value as? [String: Any] {
      if let nestedArray = dictionary["data"] as? [[String: Any]] {
        rawEntries = nestedArray
      } else if let nestedDictionary = dictionary["data"] as? [String: Any] {
        rawEntries = [nestedDictionary]
      } else {
        rawEntries = [dictionary]
      }
    } else {
      rawEntries = []
    }

    let currentUpper = currentUserID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    var usersByID: [String: ContactSearchUser] = [:]
    for rawEntry in rawEntries {
      guard let user = ContactSearchUser(payload: rawEntry) else { continue }
      let normalizedID = user.userID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      if normalizedID.isEmpty || normalizedID == currentUpper { continue }
      usersByID[normalizedID] = user
    }
    return Array(usersByID.values).sorted {
      $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
    }
  }

  private enum QueryKind {
    case userID
    case phone
    case username
  }

  private static func queryKind(for query: String) -> QueryKind {
    let digitsCount = query.filter(\.isNumber).count
    let phoneCharacters = Set(query).isSubset(of: Set("0123456789+-() ".map { $0 }))
    if phoneCharacters && digitsCount >= 7 {
      return .phone
    }
    if looksLikeUUID(query) {
      return .userID
    }
    return .username
  }

  private static func looksLikeUUID(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return UUID(uuidString: trimmed.uppercased()) != nil
  }
}

enum ContactSearchServiceError: LocalizedError {
  case invalidURL
  case invalidResponse
  case http(Int, String)

  var isSessionExpired: Bool {
    switch self {
    case let .http(statusCode, _):
      return statusCode == 401
    default:
      return false
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "The stored API configuration is invalid."
    case .invalidResponse:
      return "The server did not return a valid response."
    case let .http(statusCode, body):
      return appShellServerErrorMessage(statusCode: statusCode, body: body, fallback: "Search unavailable")
    }
  }
}

private struct ChatCreateResult {
  let chatID: String
  let messages: [[String: Any]]
}

enum ChatRoomCreationKind {
  case group
  case channel

  var displayName: String {
    switch self {
    case .group: return "Group"
    case .channel: return "Channel"
    }
  }

  var title: String {
    switch self {
    case .group: return "New Group"
    case .channel: return "New Channel"
    }
  }

  var placeholder: String {
    switch self {
    case .group: return "Group name"
    case .channel: return "Channel name"
    }
  }

  var message: String {
    switch self {
    case .group: return "Create the group now. Members can be added from the group profile."
    case .channel: return "Create a broadcast channel with you as owner."
    }
  }
}

struct ChatRoomCreateResult {
  let chatID: String
  let name: String
  let type: String
}

enum ChatRoomCreateService {
  static func create(kind: ChatRoomCreationKind, config: AppSessionConfig, name: String, memberIds: [String] = [], avatarUrl: String? = nil) async throws -> ChatRoomCreateResult {
    let activeConfig = AppSessionConfig.current ?? config
    do {
      return try await createOnce(kind: kind, config: activeConfig, name: name, memberIds: memberIds, avatarUrl: avatarUrl)
    } catch let error as ChatDirectMessageServiceError {
      guard error.isSessionExpired else {
        throw error
      }
      let refreshedConfig = try await AppSessionRefreshService.refresh(config: activeConfig)
      return try await createOnce(kind: kind, config: refreshedConfig, name: name, memberIds: memberIds, avatarUrl: avatarUrl)
    }
  }

  private static func createOnce(kind: ChatRoomCreationKind, config: AppSessionConfig, name: String, memberIds: [String] = [], avatarUrl: String? = nil) async throws -> ChatRoomCreateResult {
    let request = try buildRequest(kind: kind, config: config, name: name, memberIds: memberIds, avatarUrl: avatarUrl)

    switch config.transportMode {
    case .offline:
      throw ChatDirectMessageServiceError.transportUnavailable("offline")
    case .bridgeText:
      throw ChatDirectMessageServiceError.transportUnavailable("bridge_text")
    case .packetMesh:
      let packetSnapshot = try await PacketRuntime.shared.ensureStarted(config: config)
      let session = PacketRuntime.shared.makeURLSession(snapshot: packetSnapshot)
      return try await perform(request, fallbackName: name, session: session)
    case .direct:
      do {
        let result = try await perform(request, fallbackName: name, session: .shared)
        PacketRuntime.shared.stop(resetToDirect: true)
        Task.detached {
          await PacketBootstrapService.prefetchIfNeeded(config: config)
        }
        return result
      } catch {
        guard ChatDirectMessageService.shouldAttemptPacketFallback(for: error) else {
          throw error
        }
        let packetSnapshot = try await PacketRuntime.shared.ensureStarted(config: config)
        let session = PacketRuntime.shared.makeURLSession(snapshot: packetSnapshot)
        return try await perform(request, fallbackName: name, session: session)
      }
    }
  }

  private static func buildRequest(kind: ChatRoomCreationKind, config: AppSessionConfig, name: String, memberIds: [String] = [], avatarUrl: String? = nil) throws -> URLRequest {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }

    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    let endpoint: String
    switch kind {
    case .group:
      endpoint = "/group"
    case .channel:
      endpoint = "/channel"
    }
    guard let url = URL(string: "\(pathBase)\(endpoint)") else {
      throw ChatDirectMessageServiceError.invalidURL
    }

    var body: [String: Any] = ["name": name]
    if let avatarUrl {
      body["avatarUrl"] = avatarUrl
    }
    if case .group = kind {
      body["memberIds"] = memberIds
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  private static func perform(_ request: URLRequest, fallbackName: String, session: URLSession) async throws -> ChatRoomCreateResult {
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ChatDirectMessageServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw ChatDirectMessageServiceError.http(httpResponse.statusCode, body)
    }

    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    guard let payload = object as? [String: Any] else {
      throw ChatDirectMessageServiceError.invalidPayload
    }
    guard let chatID = ChatDirectMessageService.normalizedString(payload["chatId"] ?? payload["chat_id"]) else {
      throw ChatDirectMessageServiceError.invalidPayload
    }
    let name = ChatDirectMessageService.normalizedString(payload["name"]) ?? fallbackName
    let type = ChatDirectMessageService.normalizedString(payload["type"]) ?? "group"
    return ChatRoomCreateResult(
      chatID: chatID,
      name: name,
      type: type
    )
  }

  static func uploadAvatar(imageData: Data, config: AppSessionConfig) async throws -> String {
    let base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    let pathBase = base.hasSuffix("/") ? String(base.dropLast()) : base
    let endpoint = pathBase.lowercased().hasSuffix("/api") ? "/media/upload" : "/api/media/upload"
    guard let uploadURL = URL(string: "\(pathBase)\(endpoint)") else {
      throw ChatDirectMessageServiceError.invalidURL
    }

    let boundary = "----VibeAvatarBoundary\(UUID().uuidString)"
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 45
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    let appendField = { (name: String, value: String) in
      body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
      body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8) ?? Data())
      body.append("\(value)\r\n".data(using: .utf8) ?? Data())
    }
    appendField("user_id", config.userID)
    appendField("type", "image")

    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8) ?? Data())
    body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8) ?? Data())
    body.append(imageData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8) ?? Data())

    let (data, response) = try await URLSession.shared.upload(for: request, from: body)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw ChatDirectMessageServiceError.invalidResponse
    }
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let remoteURL = json["url"] as? String ?? json["media_url"] as? String ?? json["mediaUrl"] as? String
    else {
      throw ChatDirectMessageServiceError.invalidResponse
    }
    return remoteURL
  }
}

private enum ChatDirectMessageService {
  static func startChat(config: AppSessionConfig, friendID: String) async throws -> ChatCreateResult {
    let activeConfig = AppSessionConfig.current ?? config
    do {
      return try await startChatOnce(config: activeConfig, friendID: friendID)
    } catch let error as ChatDirectMessageServiceError {
      guard error.isSessionExpired else {
        throw error
      }
      let refreshedConfig = try await AppSessionRefreshService.refresh(config: activeConfig)
      return try await startChatOnce(config: refreshedConfig, friendID: friendID)
    }
  }

  private static func startChatOnce(config: AppSessionConfig, friendID: String) async throws -> ChatCreateResult {
    let request = try buildRequest(config: config, friendID: friendID)

    switch config.transportMode {
    case .offline:
      throw ChatDirectMessageServiceError.transportUnavailable("offline")
    case .bridgeText:
      throw ChatDirectMessageServiceError.transportUnavailable("bridge_text")
    case .packetMesh:
      let packetSnapshot = try await PacketRuntime.shared.ensureStarted(config: config)
      let session = PacketRuntime.shared.makeURLSession(snapshot: packetSnapshot)
      return try await perform(request, session: session)
    case .direct:
      do {
        let result = try await perform(request, session: .shared)
        PacketRuntime.shared.stop(resetToDirect: true)
        Task.detached {
          await PacketBootstrapService.prefetchIfNeeded(config: config)
        }
        return result
      } catch {
        guard shouldAttemptPacketFallback(for: error) else {
          throw error
        }
        let packetSnapshot = try await PacketRuntime.shared.ensureStarted(config: config)
        let session = PacketRuntime.shared.makeURLSession(snapshot: packetSnapshot)
        return try await perform(request, session: session)
      }
    }
  }

  private static func buildRequest(config: AppSessionConfig, friendID: String) throws -> URLRequest {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }

    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    guard let url = URL(string: "\(pathBase)/chat") else {
      throw ChatDirectMessageServiceError.invalidURL
    }

    let body: [String: Any] = [
      "myId": config.userID,
      "friendId": friendID,
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  private static func perform(_ request: URLRequest, session: URLSession) async throws -> ChatCreateResult {
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ChatDirectMessageServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw ChatDirectMessageServiceError.http(httpResponse.statusCode, body)
    }

    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    guard let payload = object as? [String: Any] else {
      throw ChatDirectMessageServiceError.invalidPayload
    }
    guard let chatID = normalizedString(payload["chatId"] ?? payload["chat_id"]) else {
      throw ChatDirectMessageServiceError.invalidPayload
    }

    let messages = (payload["messages"] as? [[String: Any]]) ?? []
    return ChatCreateResult(chatID: chatID, messages: messages)
  }

  fileprivate static func shouldAttemptPacketFallback(for error: Error) -> Bool {
    if let serviceError = error as? ChatDirectMessageServiceError {
      switch serviceError {
      case let .http(statusCode, _):
        return statusCode >= 500
      case .transportUnavailable:
        return false
      default:
        return true
      }
    }
    return true
  }

  fileprivate static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }
}

@MainActor
private func openAgentDirectChat(
  from presenter: UIViewController,
  agentUserId: String,
  agentName: String,
  agentUsername: String?
) async {
  guard let config = AppSessionConfig.current else {
    AppToastController.shared.show("The current session is unavailable.")
    return
  }

  do {
    let result = try await ChatDirectMessageService.startChat(
      config: config,
      friendID: agentUserId
    )
    let normalizedUsername =
      agentUsername?
      .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let title =
      normalizedUsername.flatMap { $0.isEmpty ? nil : $0 }
      ?? agentName
    let route = ChatRoute(
      chatId: result.chatID,
      title: title,
      peerUserId: agentUserId,
      avatarURI: nil,
      isGroup: false,
      initialRows: result.messages
    )
    guard let navigation = presenter.navigationController else { return }
    let controller = ChatConversationController(
      route: route,
      isDark: navigation.traitCollection.userInterfaceStyle == .dark,
      onClose: { [weak navigation] in
        navigation?.popViewController(animated: true)
      }
    )
    navigation.pushViewController(controller, animated: true)
  } catch {
    AppToastController.shared.show(error.localizedDescription)
  }
}

private enum ChatDirectMessageServiceError: LocalizedError {
  case invalidURL
  case invalidResponse
  case invalidPayload
  case http(Int, String)
  case transportUnavailable(String)

  var isSessionExpired: Bool {
    switch self {
    case let .http(statusCode, _):
      return statusCode == 401
    default:
      return false
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "The stored API configuration is invalid."
    case .invalidResponse:
      return "The server did not return a valid response."
    case .invalidPayload:
      return "The chat response could not be parsed."
    case let .http(statusCode, body):
      return appShellServerErrorMessage(statusCode: statusCode, body: body, fallback: "Chat request failed")
    case let .transportUnavailable(mode):
      return "Transport mode \(mode) is not available in the standalone native app."
    }
  }
}

private struct AppAnimatedSVGView: UIViewRepresentable {
  let svgString: String

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.allowsInlineMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = false
    webView.scrollView.bounces = false
    webView.isUserInteractionEnabled = false
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {
    let html = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
    <style>
      body, html { margin: 0; padding: 0; width: 100%; height: 100%; background-color: transparent; display: flex; justify-content: center; align-items: center; }
      svg { width: 100%; height: 100%; object-fit: contain; }
    </style>
    </head>
    <body>
    \(svgString)
    </body>
    </html>
    """
    uiView.loadHTMLString(html, baseURL: nil)
  }
}

// MARK: - Native UIKit shell

/// Root navigation controller that wraps the whole `AppRootTabBarController`.
/// Pushing a `ChatConversationController` here slides it in z-above all four
/// tabs (Calls / Contacts / Home / Settings) — a chat can be opened from any
/// tab and is never nested inside the Chats tab. Its own nav bar stays hidden;
/// each pushed surface draws its own header.
final class AppRootNavigationController: UINavigationController, UIGestureRecognizerDelegate {
  override func viewDidLoad() {
    super.viewDidLoad()
    setNavigationBarHidden(true, animated: false)
    interactivePopGestureRecognizer?.delegate = self
  }

  // Keep edge-swipe-back working while the system nav bar is hidden, but only
  // when there is something pushed above the tab shell.
  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    viewControllers.count > 1
  }

  override var childForStatusBarStyle: UIViewController? {
    return topViewController
  }
}

/// The four-tab shell (Calls / Contacts / Home / Settings). It is itself the
/// root of `AppRootNavigationController`, which is what actually pushes a chat
/// conversation — z-above this whole tab bar — so a chat opens from any tab
/// without nesting. Each tab hosts its SwiftUI page in a `UIHostingController`.
final class AppRootTabBarController: UITabBarController, UITabBarControllerDelegate {
  let coordinator = AppShellCoordinator()

  override var childForStatusBarStyle: UIViewController? {
    return selectedViewController
  }

  /// Tab order; the index maps 1:1 to `AppShellTab`.
  static let orderedTabs: [AppShellTab] = [.calls, .contacts, .chats, .search, .settings]
  static func tabIndex(for tab: AppShellTab) -> Int? { orderedTabs.firstIndex(of: tab) }

  private var toastHost: UIHostingController<AppToastHostView>?
  private var settingsAvatarTask: Task<Void, Never>?
  private var profileCancellable: AnyCancellable?

  override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self
    AppUIStallWatchdog.shared.start(context: "tabshell viewDidLoad")

    // --- Tabs (order: Calls · Contacts · Home · Settings) ----------------
    let callsVC = makeHosted(CallsRootView())
    callsVC.tabBarItem = UITabBarItem(
      title: "Calls", image: UIImage(systemName: "phone"), selectedImage: nil)

    let contactsVC = makeHosted(ContactsRootView())
    contactsVC.tabBarItem = UITabBarItem(
      title: "Contacts", image: UIImage(systemName: "person.circle"), selectedImage: nil)

    let chatHomeVC = UIHostingController(rootView: ChatHomeScreen().environmentObject(coordinator))
    chatHomeVC.tabBarItem = UITabBarItem(
      title: "Chats",
      image: UIImage(systemName: "bubble.left.and.bubble.right.fill"),
      selectedImage: nil)

    let searchVC = UIViewController()
    searchVC.tabBarItem = UITabBarItem(
      title: "Search", image: UIImage(systemName: "magnifyingglass"), selectedImage: nil)

    let settingsVC = makeHosted(SettingsRootView())
    settingsVC.tabBarItem = UITabBarItem(
      title: "Settings", image: UIImage(systemName: "gearshape"), selectedImage: nil)

    viewControllers = [callsVC, contactsVC, chatHomeVC, searchVC, settingsVC]
    selectedIndex = Self.tabIndex(for: .chats) ?? 2

    // --- Coordinator wiring ----------------------------------------------
    coordinator.tabBarController = self
    coordinator.selectedTab = .chats

    // --- Appearance & lifecycle ------------------------------------------
    configureGlobalNavigationBarAppearance()
    configureGlobalSearchBarAppearance()
    applyTabBarAppearance()
    AppAppearanceController.applyStoredPreference()
    installToastHost()

    VibeNativeCallOverlayPresenter.shared.startObserving()
    VibeNativeCallOverlayPresenter.shared.refreshFromEngine()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    refreshSettingsTabAvatar()

    Task { [weak self] in
      await AppProfileController.shared.loadIfNeeded()
      await MainActor.run { self?.refreshSettingsTabAvatar() }
    }
    profileCancellable = AppProfileController.shared.$profile
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.refreshSettingsTabAvatar()
      }
  }

  deinit {
    settingsAvatarTask?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  private func makeHosted<Content: View>(_ view: Content) -> UIViewController {
    UIHostingController(rootView: view.environmentObject(coordinator))
  }

  // MARK: Tab selection sync

  /// Re-entrancy guard/counter purely for freeze diagnosis: if a tab change
  /// ping-pongs (selectedIndex ↔ selectedTab) this climbs and the breadcrumbs
  /// show it before the watchdog reports the stall.
  private var didSelectDepth = 0

  func tabBarController(
    _ tabBarController: UITabBarController, shouldSelect viewController: UIViewController
  ) -> Bool {
    guard let index = viewControllers?.firstIndex(of: viewController),
          index < Self.orderedTabs.count else { return true }
    let tab = Self.orderedTabs[index]
    if tab == .search {
      coordinator.openChatSearch()
      return false
    }
    return true
  }

  func tabBarController(
    _ tabBarController: UITabBarController, didSelect viewController: UIViewController
  ) {
    tabBarController.view.endEditing(true)
    let index = tabBarController.selectedIndex
    guard index < Self.orderedTabs.count else { return }
    let tab = Self.orderedTabs[index]
    didSelectDepth += 1
    appShellRouteLog("tab didSelect begin depth=\(didSelectDepth) index=\(index) tab=\(tab)")
    if coordinator.selectedTab != tab {
      coordinator.selectedTab = tab
    }
    appShellRouteLog("tab didSelect end depth=\(didSelectDepth) tab=\(tab)")
    didSelectDepth -= 1
  }

  // MARK: Appearance



  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
      applyTabBarAppearance()
      configureGlobalNavigationBarAppearance()
      configureGlobalSearchBarAppearance()
    }
  }

  private var paletteForCurrentStyle: AppThemePalette {
    AppThemePalette.resolve(for: traitCollection.userInterfaceStyle == .dark ? .dark : .light)
  }

  private func applyTabBarAppearance() {
    let palette = paletteForCurrentStyle
    let appearance = UITabBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.backgroundColor = .clear
    appearance.shadowColor = .clear

    for itemAppearance in [
      appearance.stackedLayoutAppearance,
      appearance.inlineLayoutAppearance,
      appearance.compactInlineLayoutAppearance,
    ] {
      // Use standard neutral text colors for selected state to match the system behavior without forcing a vibrant accent
      itemAppearance.selected.iconColor = palette.textUIColor
      itemAppearance.selected.titleTextAttributes = [.foregroundColor: palette.textUIColor]
      itemAppearance.normal.iconColor = palette.secondaryTextUIColor
      itemAppearance.normal.titleTextAttributes = [.foregroundColor: palette.secondaryTextUIColor]
    }

    tabBar.standardAppearance = appearance
    tabBar.scrollEdgeAppearance = appearance
    tabBar.tintColor = palette.textUIColor
    tabBar.unselectedItemTintColor = palette.secondaryTextUIColor
  }

  private func configureGlobalNavigationBarAppearance() {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.shadowColor = .clear
    appearance.backgroundColor = .clear
    UINavigationBar.appearance().standardAppearance = appearance
    UINavigationBar.appearance().scrollEdgeAppearance = appearance
    UINavigationBar.appearance().compactAppearance = appearance
  }

  // The transparent navigation bar above leaves .searchable()'s text field with no
  // background of its own, so it reads as a faint, undefined-looking strip. Give it an
  // explicit, theme-aware fill via the appearance proxy since SwiftUI's .searchable()
  // exposes no direct styling hook for the field it creates.
  private func configureGlobalSearchBarAppearance() {
    let palette = paletteForCurrentStyle
    let textFieldAppearance = UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self])
    textFieldAppearance.backgroundColor = palette.inputUIColor
    textFieldAppearance.textColor = palette.textUIColor
    UISearchBar.appearance().tintColor = palette.textUIColor
  }

  // MARK: Settings tab avatar

  @objc private func handleDidBecomeActive() {
    VibeNativeCallOverlayPresenter.shared.refreshFromEngine()
    refreshSettingsTabAvatar()
  }

  private func refreshSettingsTabAvatar() {
    settingsAvatarTask?.cancel()
    let profile = AppProfileController.shared.profile
    guard let uri = profile?.profileImage, !uri.isEmpty else {
      applySettingsTabFallback(profile: profile)
      return
    }
    settingsAvatarTask = Task { [weak self] in
      let image = await ChatAvatarImageStore.load(from: uri)
      if Task.isCancelled { return }
      await MainActor.run {
        if let img = image {
          self?.applySettingsTabImage(img)
        } else {
          self?.applySettingsTabFallback(profile: profile)
        }
      }
    }
  }

  private func applySettingsTabFallback(profile: AppUserProfile?) {
    let name = profile?.name ?? profile?.username ?? "U"
    let letters = String(name.prefix(2)).uppercased()
    let colors = ChatProfileAppearanceStore.avatarColors(
      title: profile?.displayName ?? name,
      peerUserId: profile?.userID,
      chatId: profile?.username
    )

    let size: CGFloat = 26
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    let image = renderer.image { ctx in
      let rect = CGRect(x: 0, y: 0, width: size, height: size)
      UIBezierPath(ovalIn: rect).addClip()
      let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [colors.0.cgColor, colors.1.cgColor] as CFArray,
        locations: [0.0, 1.0]
      )
      if let gradient {
        ctx.cgContext.drawLinearGradient(
          gradient,
          start: CGPoint(x: 0.0, y: 0.0),
          end: CGPoint(x: size, y: size),
          options: []
        )
      } else {
        colors.0.setFill()
        ctx.cgContext.fill(rect)
      }

      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: size * 0.45, weight: .semibold),
        .foregroundColor: UIColor.white
      ]
      let textSize = letters.size(withAttributes: attributes)
      let textRect = CGRect(
        x: (size - textSize.width) / 2,
        y: (size - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height
      )
      letters.draw(in: textRect, withAttributes: attributes)
    }
    applySettingsTabImage(image)
  }

  private func applySettingsTabImage(_ image: UIImage?) {
    guard let settingsIndex = Self.tabIndex(for: .settings),
      let controllers = viewControllers, settingsIndex < controllers.count
    else { return }
    let item = controllers[settingsIndex].tabBarItem
    if let image, let circular = Self.circularTabImage(from: image, size: 26) {
      item?.image = circular
      item?.selectedImage = circular
    } else {
      let fallback = UIImage(systemName: "gearshape")
      item?.image = fallback
      item?.selectedImage = fallback
    }
  }

  private static func circularTabImage(from source: UIImage, size: CGFloat) -> UIImage? {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    let image = renderer.image { ctx in
      let rect = CGRect(x: 0, y: 0, width: size, height: size)
      UIBezierPath(ovalIn: rect).addClip()
      source.draw(in: rect)

      ctx.cgContext.resetClip()
      let badgeSize: CGFloat = 8
      let badgeRect = CGRect(x: size - badgeSize, y: size - badgeSize, width: badgeSize, height: badgeSize)
      let badgePath = UIBezierPath(ovalIn: badgeRect)
      UIColor.systemGreen.setFill()
      badgePath.fill()
      UIColor.black.setStroke()
      badgePath.lineWidth = 1.5
      badgePath.stroke()
    }
    return image.withRenderingMode(.alwaysOriginal)
  }

  // MARK: Toast host

  private func installToastHost() {
    let host = UIHostingController(rootView: AppToastHostView())
    host.view.backgroundColor = .clear
    host.view.isUserInteractionEnabled = false
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
    toastHost = host
  }
}

/// Floating toast overlay hosted above the whole tab shell (including a pushed
/// conversation) so it stays visible while a chat is open. Non-interactive.
private struct AppToastHostView: View {
  @ObservedObject private var toast = AppToastController.shared
  @Environment(\.colorScheme) private var colorScheme

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    VStack {
      Spacer()
      if let message = toast.message {
        AppToastBanner(message: message, palette: palette)
          .padding(.horizontal, 20)
          .padding(.bottom, 100)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(.spring(response: 0.3, dampingFraction: 0.82), value: toast.message)
    .allowsHitTesting(false)
  }
}

// MARK: - Agent conversation (real chat UI + headless agent transport)

/// The "talk to the agent" surface. Renders with the real chat stack
/// (`ChatMainView` → `ChatListView`: same wallpaper / theme / bubbles / streaming
/// cell / `ChatInputBar`) while a hidden `ChatNativeAgentView` runs headless as
/// the transport + row source — it owns the proven `agent:<userId>` socket,
/// streaming, and persistence, and emits rows in the same `kind`/`message`
/// envelope the chat list consumes. Agent-specific conditions: first message
/// pinned to top, and the composer's send button becomes a stop button while the
/// agent is streaming.
final class ChatAgentConversationController: UIViewController {
  private let mainView = ChatMainView()
  private let agentView = ChatNativeAgentView(frame: .zero)
  private let isDark: Bool
  private var onClose: (() -> Void)?

  init(isDark: Bool, onClose: (() -> Void)?) {
    self.isDark = isDark
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    isDark ? .lightContent : .darkContent
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = isDark ? .black : .white

    let appearance: [String: Any] = [
      "theme": isDark ? "dark" : "light",
      "backgroundMode": "gradient",
      "wallpaperOpacity": 1.0,
      "nativeThemeId": AppThemePlateController.currentOption.rawValue,
      "nativeThemeIsDark": isDark,
    ]

    // Headless transport: hidden but in the hierarchy so it gets a window and
    // connects the agent socket. It produces rows + streaming state. It must be
    // given a real (non-zero) frame even while hidden — at width 0 its internal
    // messages view floods the console with unsatisfiable-constraint warnings.
    agentView.isHidden = true
    agentView.isUserInteractionEnabled = false
    agentView.frame = UIScreen.main.bounds
    agentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    agentView.surfaceId = "native_agent_transport"
    agentView.setAppearance(appearance)
    agentView.onRowsChanged = { [weak self] rows in
      self?.mainView.setRows(rows)
    }
    agentView.onStreamingStateChanged = { [weak self] streaming in
      self?.mainView.setAgentStreaming(streaming)
    }
    agentView.onNativeEvent.handler = { [weak self] payload in
      self?.handleAgentEvent(payload)
    }
    view.addSubview(agentView)

    // Visible chat surface — the real chat UI, driven directly (no engine).
    mainView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(mainView)
    NSLayoutConstraint.activate([
      mainView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      mainView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      mainView.topAnchor.constraint(equalTo: view.topAnchor),
      mainView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    mainView.onNativeEvent.handler = { [weak self] payload in
      self?.handleMainEvent(payload)
    }
    mainView.setExternalNavigationHeaderEnabled(false)
    mainView.surfaceId = "native_agent_chat"
    mainView.setDefersEngineStateRefreshes(true)
    mainView.setEngineChannelBindingEnabled(false)
    mainView.setStatusAuthorityEnabled(false)
    mainView.setAppearance(appearance)
    mainView.setHeaderMode("default")
    mainView.setHeaderTitle("Vibe AI")
    mainView.setProfileName("Vibe AI")
    mainView.setHeaderSubtitle("AI agent")
    mainView.setIsGroupOrChannel(false)
    mainView.setAgentChatMode(true)
    mainView.setInputPlaceholder("Message Vibe AI")
    mainView.setInputBarEnabled(true)
    // Route sends to us (the agent transport) instead of the chat engine.
    mainView.setNativeSendEnabled(false)
    mainView.setPage(ChatConversationPage.chat.rawValue, animated: false)
    agentView.synchronizeHostState()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(true, animated: false)
  }

  private func handleMainEvent(_ payload: [String: Any]) {
    let type = (payload["type"] as? String) ?? ""
    switch type {
    case "headerBack":
      onClose?()
    case "sendMessage":
      let text = ((payload["text"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      agentView.submitText(text, userMessageId: payload["messageId"] as? String)
    case "agentStopStreaming":
      agentView.stopStreaming()
    case "openAgentPanel":
      agentView.presentAgentControlPanel(from: self)
    case "agentCreateRequested":
      mainView.setComposerText("Create a new agent", focus: true)
    case "agentChatPressed":
      guard
        let agentUserId =
          (payload["agentUserId"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !agentUserId.isEmpty
      else { return }
      let agentName = (payload["agentName"] as? String) ?? "Agent"
      let agentUsername =
        (payload["agentUsername"] as? String)
        ?? (payload["agentHandle"] as? String)
      Task { @MainActor [weak self] in
        guard let self else { return }
        await openAgentDirectChat(
          from: self,
          agentUserId: agentUserId,
          agentName: agentName,
          agentUsername: agentUsername
        )
      }
    default:
      agentView.handleHostEvent(payload)
    }
  }

  private func handleAgentEvent(_ payload: [String: Any]) {
    let type = (payload["type"] as? String) ?? ""
    switch type {
    case "agentToast":
      if let message = payload["message"] as? String, !message.isEmpty {
        AppToastController.shared.show(message)
      }
    case "agentCreateRequested":
      mainView.setComposerText("Create a new agent", focus: true)
    case "agentChatPressed":
      guard
        let agentUserId =
          (payload["agentUserId"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !agentUserId.isEmpty
      else { return }
      let agentName = (payload["agentName"] as? String) ?? "Agent"
      let agentUsername =
        (payload["agentUsername"] as? String)
        ?? (payload["agentHandle"] as? String)
      Task { @MainActor [weak self] in
        guard let self else { return }
        await openAgentDirectChat(
          from: self,
          agentUserId: agentUserId,
          agentName: agentName,
          agentUsername: agentUsername
        )
      }
    default:
      break
    }
  }
}
