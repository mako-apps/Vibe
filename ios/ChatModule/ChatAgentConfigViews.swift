import SwiftUI
import UIKit

/// One entry in the agent tool catalog (mirrors the backend ToolRegistry).
struct ChatAgentToolInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
}

/// A prompt argument the agent's system prompt references via {{name}}.
/// `locked` is true when the value is pinned in backend code and cannot be
/// edited from the app (shown read-only).
struct ChatAgentPromptVariable: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    var value: String
    let locked: Bool
}

class ChatAgentConfigViewModel: ObservableObject {
    @Published var card: ChatListRow.AgentCard

    var onRename: ((String, @escaping (Bool) -> Void) -> Void)?
    var onSavePrompt: ((String, @escaping (Bool) -> Void) -> Void)?
    var onSetStatus: ((Bool) -> Void)?
    var onUpdateEventInboxMode: ((String, String, Int, [String], @escaping (Bool) -> Void) -> Void)?
    var onCopy: ((String) -> Void)?
    var onToast: ((String) -> Void)?

    /// Present the native photo picker / camera flow to set the agent avatar.
    var onPickAvatar: (() -> Void)?
    /// Live handle availability check. Returns (available, reason?) where reason
    /// is a short server code such as "username_taken" when unavailable.
    var onCheckUsername: ((String, @escaping (Bool, String?) -> Void) -> Void)?
    /// Persist a new handle. Returns (success, errorMessage?).
    var onSaveUsername: ((String, @escaping (Bool, String?) -> Void) -> Void)?
    /// Load the tool catalog the agent can be granted.
    var onLoadToolRegistry: ((@escaping ([ChatAgentToolInfo]) -> Void) -> Void)?
    /// Persist the agent's enabled tool ids.
    var onSaveTools: (([String], @escaping (Bool) -> Void) -> Void)?
    /// Load the agent's configured prompt variables (name/value/locked).
    var onLoadPromptVariables: ((@escaping ([ChatAgentPromptVariable]) -> Void) -> Void)?
    /// Persist updated prompt variable values. Returns success.
    var onSavePromptVariables: (([ChatAgentPromptVariable], @escaping (Bool) -> Void) -> Void)?

    init(card: ChatListRow.AgentCard) {
        self.card = card
    }
}

struct ChatAgentSettingsView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @State private var draftName: String = ""
    @State private var isSavingName = false

    private var promptSummary: String {
        let prompt = (viewModel.card.systemPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? "Not set" : prompt
    }

    private var toolsSummary: String {
        let count = viewModel.card.enabledTools.count
        switch count {
        case 0: return "None"
        case 1: return "1 tool"
        default: return "\(count) tools"
        }
    }

    var body: some View {
        Form {
            // Profile / avatar — tappable to change the agent's photo.
            Section {
                HStack {
                    Spacer()
                    Button(action: { viewModel.onPickAvatar?() }) {
                        ChatAgentAvatarView(
                            avatarUrl: viewModel.card.avatarUrl,
                            displayName: viewModel.card.displayName,
                            size: 88
                        )
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.accentColor)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)

                Button("Change Photo") { viewModel.onPickAvatar?() }
                    .frame(maxWidth: .infinity, alignment: .center)
            } header: {
                Text("Profile")
            }

            Section {
                HStack {
                    TextField("Agent Name", text: $draftName)
                        .onSubmit { saveName() }

                    if isSavingName {
                        ProgressView().controlSize(.small)
                    } else if draftName != viewModel.card.displayName {
                        Button("Save") { saveName() }
                    }
                }

                NavigationLink(destination: ChatAgentUsernameView(viewModel: viewModel)) {
                    HStack {
                        Text("Handle")
                        Spacer()
                        Text(viewModel.card.username.map { "@\($0)" } ?? "Not set")
                            .foregroundColor(.secondary)
                    }
                }

                Toggle("Active (Published)", isOn: Binding(
                    get: { viewModel.card.status.lowercased() == "published" },
                    set: { newValue in viewModel.onSetStatus?(newValue) }
                ))
            } header: {
                Text("Agent Identity")
            } footer: {
                if viewModel.card.status.lowercased() == "published" {
                    Text("The handle is locked while the agent is published. Revert to draft to change it.")
                }
            }

            Section {
                NavigationLink(destination: ChatAgentPromptView(viewModel: viewModel)) {
                    HStack {
                        Text("System Prompt")
                        Spacer()
                        Text(promptSummary)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                NavigationLink(destination: ChatAgentToolsView(viewModel: viewModel)) {
                    HStack {
                        Text("Tools")
                        Spacer()
                        Text(toolsSummary)
                            .foregroundColor(.secondary)
                    }
                }

                NavigationLink(destination: ChatAgentPromptVariablesView(viewModel: viewModel)) {
                    Text("Prompt Variables")
                }

                NavigationLink("Integration & Delivery", destination: ChatAgentIntegrationView(viewModel: viewModel))
                NavigationLink("Output Controls", destination: ChatAgentOutputSettingsView(viewModel: viewModel))
                NavigationLink("Voice Settings", destination: ChatAgentVoiceSettingsView(viewModel: viewModel))
            } header: {
                Text("Configuration")
            }
        }
        .onAppear {
            draftName = viewModel.card.displayName
        }
        .onChange(of: viewModel.card) { newCard in
            if !isSavingName {
                draftName = newCard.displayName
            }
        }
    }

    private func saveName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != viewModel.card.displayName else { return }
        isSavingName = true
        viewModel.onRename?(trimmed) { success in
            isSavingName = false
            if !success {
                draftName = viewModel.card.displayName
            }
        }
    }
}

/// Circular agent avatar: remote image when available, gradient initial otherwise.
struct ChatAgentAvatarView: View {
    let avatarUrl: String?
    let displayName: String
    var size: CGFloat = 44

    private var initial: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(1)).uppercased()
    }

    var body: some View {
        Group {
            if let avatarUrl, let url = URL(string: avatarUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        ZStack { placeholder; ProgressView() }
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
    }
}

/// Inner page for editing the agent's system prompt.
struct ChatAgentPromptView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draftPrompt: String = ""
    @State private var isSaving = false

    private var isDirty: Bool {
        draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            != (viewModel.card.systemPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draftPrompt)
                    .frame(minHeight: 240)
            } header: {
                Text("System Prompt")
            } footer: {
                Text("Defines how the agent behaves and responds.")
            }
        }
        .navigationTitle("System Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { savePrompt() }
                        .disabled(!isDirty)
                }
            }
        }
        .onAppear { draftPrompt = viewModel.card.systemPrompt ?? "" }
    }

    private func savePrompt() {
        let trimmed = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        viewModel.onSavePrompt?(trimmed) { success in
            isSaving = false
            if success {
                dismiss()
            } else {
                draftPrompt = viewModel.card.systemPrompt ?? ""
            }
        }
    }
}

/// Inner page to change the agent handle with live availability checking.
struct ChatAgentUsernameView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @State private var isChecking = false
    @State private var isSaving = false
    @State private var availability: Availability = .unknown
    @State private var debounceWork: DispatchWorkItem?

    private enum Availability: Equatable {
        case unknown
        case available
        case unavailable(String)
    }

    private var normalized: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }

    private var isUnchanged: Bool {
        normalized == (viewModel.card.username ?? "").lowercased()
    }

    private var published: Bool {
        viewModel.card.status.lowercased() == "published"
    }

    private var canSave: Bool {
        if published || isSaving || normalized.isEmpty || isUnchanged { return false }
        if case .available = availability { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("@")
                        .foregroundColor(.secondary)
                    TextField("handle", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .disabled(published)
                        .onChange(of: draft) { _ in scheduleCheck() }
                    statusIcon
                }
            } header: {
                Text("Handle")
            } footer: {
                footerText
            }
        }
        .navigationTitle("Handle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { save() }.disabled(!canSave)
                }
            }
        }
        .onAppear { draft = viewModel.card.username ?? "" }
    }

    @ViewBuilder private var statusIcon: some View {
        if isChecking {
            ProgressView().controlSize(.small)
        } else if isUnchanged || normalized.isEmpty {
            EmptyView()
        } else {
            switch availability {
            case .available:
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            case .unavailable:
                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
            case .unknown:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var footerText: some View {
        if published {
            Text("The handle is locked while the agent is published. Revert to draft to change it.")
        } else if isUnchanged || normalized.isEmpty {
            Text("3–30 characters: lowercase letters, numbers, and underscores.")
        } else {
            switch availability {
            case .available:
                Text("@\(normalized) is available.").foregroundColor(.green)
            case .unavailable(let reason):
                Text(Self.message(for: reason)).foregroundColor(.red)
            case .unknown:
                Text("3–30 characters: lowercase letters, numbers, and underscores.")
            }
        }
    }

    private func scheduleCheck() {
        debounceWork?.cancel()
        availability = .unknown
        guard !normalized.isEmpty, !isUnchanged, !published else {
            isChecking = false
            return
        }
        let work = DispatchWorkItem { runCheck() }
        debounceWork = work
        isChecking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func runCheck() {
        let candidate = normalized
        viewModel.onCheckUsername?(candidate) { available, reason in
            guard candidate == normalized else { return }
            isChecking = false
            availability = available ? .available : .unavailable(reason ?? "unavailable")
        }
    }

    private func save() {
        isSaving = true
        viewModel.onSaveUsername?(normalized) { success, errorMessage in
            isSaving = false
            if success {
                dismiss()
            } else if let errorMessage {
                availability = .unavailable(errorMessage)
            }
        }
    }

    static func message(for reason: String) -> String {
        switch reason {
        case "username_taken": return "That handle is already taken."
        case "reserved_username": return "That handle is reserved."
        case "invalid_username": return "Use 3–30 lowercase letters, numbers, or underscores."
        case "username_locked_after_publish": return "Handle is locked while published."
        default: return reason
        }
    }
}

/// Inner page to grant/revoke the agent's tools.
struct ChatAgentToolsView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var tools: [ChatAgentToolInfo] = []
    @State private var enabled: Set<String> = []
    @State private var isLoading = true
    @State private var isSaving = false

    private var isDirty: Bool {
        enabled != Set(viewModel.card.enabledTools)
    }

    var body: some View {
        Form {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else {
                Section {
                    ForEach(tools) { tool in
                        Toggle(isOn: Binding(
                            get: { enabled.contains(tool.id) },
                            set: { on in
                                if on { enabled.insert(tool.id) } else { enabled.remove(tool.id) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name)
                                Text(tool.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Tools")
                } footer: {
                    Text("Choose which capabilities this agent can use.")
                }
            }
        }
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { save() }.disabled(!isDirty)
                }
            }
        }
        .onAppear {
            enabled = Set(viewModel.card.enabledTools)
            loadTools()
        }
    }

    private func loadTools() {
        guard let loader = viewModel.onLoadToolRegistry else {
            isLoading = false
            return
        }
        loader { loaded in
            tools = loaded
            isLoading = false
        }
    }

    private func save() {
        isSaving = true
        viewModel.onSaveTools?(Array(enabled)) { success in
            isSaving = false
            if success { dismiss() }
        }
    }
}

struct ChatAgentPromptVariablesView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var variables: [ChatAgentPromptVariable] = []
    @State private var original: [ChatAgentPromptVariable] = []
    @State private var isLoading = true
    @State private var isSaving = false

    private var isDirty: Bool { variables != original }

    var body: some View {
        Form {
            if isLoading {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            } else if variables.isEmpty {
                Section {
                    Text("No prompt variables yet. Add {{variable}} placeholders in your system prompt, then define their values here so you can change wording without rewriting the prompt.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                ForEach($variables) { $variable in
                    Section {
                        if variable.locked {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("{{\(variable.name)}}").font(.subheadline.monospaced())
                                    Text(variable.value.isEmpty ? "—" : variable.value)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "lock.fill").foregroundColor(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("{{\(variable.name)}}").font(.subheadline.monospaced())
                                TextField("Value", text: $variable.value)
                            }
                        }
                    } footer: {
                        if !variable.description.isEmpty {
                            Text(variable.locked ? "\(variable.description) · pinned in code" : variable.description)
                        } else if variable.locked {
                            Text("Pinned in code")
                        }
                    }
                }
            }
        }
        .navigationTitle("Prompt Variables")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { save() }.disabled(!isDirty)
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard let loader = viewModel.onLoadPromptVariables else {
            isLoading = false
            return
        }
        loader { loaded in
            variables = loaded
            original = loaded
            isLoading = false
        }
    }

    private func save() {
        isSaving = true
        viewModel.onSavePromptVariables?(variables) { success in
            isSaving = false
            if success { dismiss() }
        }
    }
}

struct ChatAgentIntegrationView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @State private var inboxMode: String = "per_event"
    @State private var incomingChatEnabled: Bool = true
    
    var body: some View {
        Form {
            Section {
                copyableRow(title: "API Base", value: viewModel.card.apiBaseURL)
                copyableRow(title: "Events URL", value: viewModel.card.eventsURL)
                copyableRow(title: "Invoke URL", value: viewModel.card.invokeURL)
                copyableRow(title: "Callback URL", value: viewModel.card.callbackURL)
            } header: {
                Text("Endpoints")
            }
            
            Section {
                copyableRow(title: "Default Chat", value: viewModel.card.defaultDestinationChat?.chatId)
                ForEach(viewModel.card.attachedChats, id: \.chatId) { chat in
                    copyableRow(title: "Attached Chat", value: chat.chatId)
                }
            } header: {
                Text("Delivery Channels")
            }
            
            Section {
                Picker("Inbox Mode", selection: $inboxMode) {
                    Text("Per Event").tag("per_event")
                    Text("Batched Summary").tag("batched_summary")
                }
                .onChange(of: inboxMode) { newValue in
                    // Call backend later
                    viewModel.onToast?("Inbox mode set to \(newValue == "batched_summary" ? "Batched" : "Per Event")")
                }
                
                Toggle("Accept Incoming Chat", isOn: $incomingChatEnabled)
            } header: {
                Text("Settings")
            }
        }
        .navigationTitle("Integration & Delivery")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            inboxMode = viewModel.card.eventInboxMode
            incomingChatEnabled = viewModel.card.incomingChatEnabled
        }
    }
    
    private func copyableRow(title: String, value: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value ?? "Not set")
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let value = value, !value.isEmpty {
                Button(action: {
                    viewModel.onCopy?(value)
                    viewModel.onToast?("Copied \(title)")
                }) {
                    Image(systemName: "square.on.square")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ChatAgentOutputSettingsView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @State private var enableText = true
    @State private var enableMessages = true
    @State private var enableMedia = false
    @State private var enableVoice = false
    
    var body: some View {
        Form {
            Section {
                Toggle("Text Output", isOn: $enableText)
                Toggle("Messages", isOn: $enableMessages)
                Toggle("Media Generation", isOn: $enableMedia)
                Toggle("Voice Output", isOn: $enableVoice)
            } header: {
                Text("Allowed Modalities")
            } footer: {
                Text("Control what modalities the agent is permitted to return. Backend sync to be added.")
            }
        }
        .navigationTitle("Output Controls")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let modes = viewModel.card.outputModes
            enableText = modes.contains("text") || modes.isEmpty // default
            enableMessages = modes.contains("messages") || modes.isEmpty
            enableMedia = modes.contains("media")
            enableVoice = modes.contains("voice")
        }
    }
}

struct ChatAgentVoiceSettingsView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @State private var selectedVoice = "alloy"
    @State private var voiceSpeed: Double = 1.0
    
    let voices = ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]
    
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.1), Color.blue.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            
            VStack(spacing: 30) {
                Spacer().frame(height: 20)
                
                // Animated shader mock
                ZStack {
                    Circle()
                        .fill(RadialGradient(gradient: Gradient(colors: [.cyan.opacity(0.8), .blue.opacity(0.4), .clear]), center: .center, startRadius: 10, endRadius: 120))
                        .frame(width: 240, height: 240)
                        .blur(radius: 20)
                    
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        .frame(width: 180, height: 180)
                    
                    Image(systemName: "waveform")
                        .font(.system(size: 60))
                        .foregroundColor(.white)
                }
                
                Text("Voice Personality")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(voices, id: \.self) { voice in
                            VStack(spacing: 8) {
                                Circle()
                                    .fill(selectedVoice == voice ? Color.white : Color.white.opacity(0.1))
                                    .frame(width: 64, height: 64)
                                    .overlay(
                                        Image(systemName: selectedVoice == voice ? "play.fill" : "play")
                                            .foregroundColor(selectedVoice == voice ? .black : .white)
                                    )
                                Text(voice.capitalized)
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundColor(selectedVoice == voice ? .white : .gray)
                            }
                            .onTapGesture {
                                withAnimation(.spring()) {
                                    selectedVoice = voice
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.top, 20)
                
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Speed")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        Spacer()
                        Text(String(format: "%.1fx", voiceSpeed))
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(.white)
                    }
                    Slider(value: $voiceSpeed, in: 0.5...2.0, step: 0.1)
                        .accentColor(.white)
                }
                .padding(.horizontal, 30)
                .padding(.top, 20)
                
                Spacer()
            }
        }
        .navigationTitle("Voice Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}
