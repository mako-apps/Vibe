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

struct ChatAgentModelInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let tier: String
    let recommended: Bool
}

struct ChatAgentModelProviderInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let available: Bool
    let models: [ChatAgentModelInfo]
}

struct ChatAgentModelRegistry: Equatable {
    let defaultProvider: String
    let defaultModelId: String
    let providers: [ChatAgentModelProviderInfo]
    let isFallback: Bool

    func provider(id: String) -> ChatAgentModelProviderInfo? {
        providers.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    func model(providerId: String, modelId: String) -> ChatAgentModelInfo? {
        provider(id: providerId)?.models.first {
            $0.id.caseInsensitiveCompare(modelId) == .orderedSame
        }
    }

    static let fallback = ChatAgentModelRegistry(
        defaultProvider: "anthropic",
        defaultModelId: "claude-sonnet-5",
        providers: [
            ChatAgentModelProviderInfo(
                id: "anthropic",
                name: "Anthropic",
                available: true,
                models: [
                    ChatAgentModelInfo(
                        id: "claude-fable-5",
                        name: "Fable 5",
                        description: "Deep reasoning for complex decisions.",
                        tier: "frontier",
                        recommended: false),
                    ChatAgentModelInfo(
                        id: "claude-opus-4-8",
                        name: "Opus 4.8",
                        description: "Maximum capability for demanding work.",
                        tier: "frontier",
                        recommended: false),
                    ChatAgentModelInfo(
                        id: "claude-sonnet-5",
                        name: "Sonnet 5",
                        description: "Fast, capable, and recommended for most agents.",
                        tier: "balanced",
                        recommended: true),
                    ChatAgentModelInfo(
                        id: "claude-haiku-4-5-20251001",
                        name: "Haiku 4.5",
                        description: "Quick responses for lightweight tasks.",
                        tier: "fast",
                        recommended: false),
                ]),
            ChatAgentModelProviderInfo(
                id: "openai",
                name: "OpenAI",
                available: true,
                models: [
                    ChatAgentModelInfo(
                        id: "gpt-5.6-sol",
                        name: "GPT-5.6 Sol",
                        description: "Maximum capability for demanding work.",
                        tier: "frontier",
                        recommended: false),
                    ChatAgentModelInfo(
                        id: "gpt-5.6-terra",
                        name: "GPT-5.6 Terra",
                        description: "A strong balance of speed and capability.",
                        tier: "balanced",
                        recommended: true),
                    ChatAgentModelInfo(
                        id: "gpt-5.6-luna",
                        name: "GPT-5.6 Luna",
                        description: "Fast and efficient for everyday tasks.",
                        tier: "fast",
                        recommended: false),
                ]),
        ],
        isFallback: true
    )
}

enum ChatAgentModelRegistryService {
    static func load(
        apiBaseURL: URL,
        token: String,
        completion: @escaping (ChatAgentModelRegistry) -> Void
    ) {
        let base = apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/agents/model_registry") else {
            completion(.fallback)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
            data, response, error in
            DispatchQueue.main.async {
                guard
                    error == nil,
                    (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
                    let data,
                    let payload =
                        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                    let registry = parse(payload)
                else {
                    completion(.fallback)
                    return
                }
                completion(registry)
            }
        }.resume()
    }

    static func parse(_ payload: [String: Any]) -> ChatAgentModelRegistry? {
        guard
            let defaultSelection = payload["default"] as? [String: Any],
            let defaultProvider = normalizedString(defaultSelection["provider"]),
            let defaultModelId = normalizedString(
                defaultSelection["modelId"] ?? defaultSelection["model_id"]),
            let rawProviders = payload["providers"] as? [[String: Any]]
        else {
            return nil
        }

        let providers: [ChatAgentModelProviderInfo] = rawProviders.compactMap { rawProvider in
            guard
                let id = normalizedString(rawProvider["id"]),
                let rawModels = rawProvider["models"] as? [[String: Any]]
            else {
                return nil
            }
            let models: [ChatAgentModelInfo] = rawModels.compactMap { rawModel in
                guard let modelId = normalizedString(rawModel["id"]) else { return nil }
                return ChatAgentModelInfo(
                    id: modelId,
                    name: normalizedString(rawModel["name"]) ?? modelId,
                    description: normalizedString(rawModel["description"]) ?? "",
                    tier: normalizedString(rawModel["tier"]) ?? "",
                    recommended: boolean(rawModel["recommended"]) ?? false
                )
            }
            let providerName: String
            switch id.lowercased() {
            case "anthropic":
                providerName = "Anthropic"
            case "openai":
                providerName = "OpenAI"
            default:
                providerName = normalizedString(rawProvider["name"]) ?? id
            }
            return ChatAgentModelProviderInfo(
                id: id,
                name: providerName,
                available: boolean(rawProvider["available"]) ?? false,
                models: models
            )
        }

        guard !providers.isEmpty else { return nil }
        return ChatAgentModelRegistry(
            defaultProvider: defaultProvider,
            defaultModelId: defaultModelId,
            providers: providers,
            isFallback: false
        )
    }

    private static func normalizedString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boolean(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

class ChatAgentConfigViewModel: ObservableObject {
    @Published var card: ChatListRow.AgentCard
    @Published var modelRegistry: ChatAgentModelRegistry = .fallback

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
    /// Load the server-authoritative provider/model catalog.
    var onLoadModelRegistry: ((@escaping (ChatAgentModelRegistry) -> Void) -> Void)?
    /// Persist one exact provider/model pair.
    var onSaveModelSelection: ((String, String, @escaping (Bool) -> Void) -> Void)?

    init(card: ChatListRow.AgentCard) {
        self.card = card
    }
}

struct ChatAgentSettingsView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel
    @State private var draftName: String = ""
    @State private var isSavingName = false
    @State private var didLoadModelRegistry = false

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

    private var modelSummary: String {
        // A cached card without the new fields represents an existing agent,
        // whose previous effective runtime was Anthropic Haiku 4.5.
        let providerId = viewModel.card.modelProvider ?? "anthropic"
        let modelId = viewModel.card.modelId ?? "claude-haiku-4-5-20251001"
        let provider =
            viewModel.modelRegistry.provider(id: providerId)
            ?? ChatAgentModelRegistry.fallback.provider(id: providerId)
        let model =
            viewModel.modelRegistry.model(providerId: providerId, modelId: modelId)
            ?? ChatAgentModelRegistry.fallback.model(providerId: providerId, modelId: modelId)
        return "\(provider?.name ?? providerId) · \(model?.name ?? modelId)"
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
                NavigationLink(destination: ChatAgentModelPickerView(viewModel: viewModel)) {
                    HStack {
                        Text("Model")
                        Spacer()
                        Text(modelSummary)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

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
            guard !didLoadModelRegistry else { return }
            didLoadModelRegistry = true
            viewModel.onLoadModelRegistry? { registry in
                viewModel.modelRegistry = registry
            }
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

struct ChatAgentModelPickerView: View {
    @ObservedObject var viewModel: ChatAgentConfigViewModel

    var body: some View {
        ChatProviderModelPickerView(
            registry: viewModel.modelRegistry,
            currentProviderId: viewModel.card.modelProvider ?? "anthropic",
            currentModelId: viewModel.card.modelId ?? "claude-haiku-4-5-20251001"
        ) { providerId, modelId, completion in
            viewModel.onSaveModelSelection?(providerId, modelId, completion)
        }
    }
}

/// Reusable server-registry-backed provider/model picker. Standalone agent
/// settings supply a server save closure; built-in VibeAgent supplies a local
/// selection closure while using the exact same catalog and validation UI.
struct ChatProviderModelPickerView: View {
    let registry: ChatAgentModelRegistry
    let currentProviderId: String
    let currentModelId: String
    let onSave: (String, String, @escaping (Bool) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProviderId = ""
    @State private var selectedModelId = ""
    @State private var isSaving = false

    private var selectedProvider: ChatAgentModelProviderInfo? {
        registry.provider(id: selectedProviderId)
    }

    private var selectedPairIsValid: Bool {
        guard let provider = selectedProvider, provider.available else { return false }
        return provider.models.contains { $0.id == selectedModelId }
    }

    private var isDirty: Bool {
        selectedProviderId != currentProviderId || selectedModelId != currentModelId
    }

    var body: some View {
        Form {
            Section {
                ForEach(registry.providers) { provider in
                    Button {
                        selectProvider(provider)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(provider.name)
                                    .foregroundColor(provider.available ? .primary : .secondary)
                                if !provider.available {
                                    Text("Unavailable — this provider is not configured.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if selectedProviderId == provider.id {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                            }
                        }
                    }
                    .disabled(!provider.available)
                }
            } header: {
                Text("Provider")
            } footer: {
                if registry.isFallback {
                    Text("Showing the built-in catalog while the live registry is unavailable. The server validates every selection.")
                }
            }

            Section {
                if let provider = selectedProvider {
                    ForEach(provider.models) { model in
                        Button {
                            selectedModelId = model.id
                        } label: {
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(model.name)
                                            .foregroundColor(provider.available ? .primary : .secondary)
                                        if model.recommended {
                                            Text("Recommended")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                    Text(model.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer()
                                if selectedModelId == model.id {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                }
                            }
                        }
                        .disabled(!provider.available)
                    }
                } else {
                    Text("Select an available provider first.")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Model")
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Save") { saveSelection() }
                        .disabled(!isDirty || !selectedPairIsValid)
                }
            }
        }
        .onAppear {
            resolveSelection()
        }
        .onChange(of: registry) { _ in
            resolveSelection()
        }
    }

    private func resolveSelection() {
        if let currentProvider = registry.provider(id: currentProviderId) {
            selectedProviderId = currentProvider.id
            if currentProvider.models.contains(where: { $0.id == currentModelId }) {
                selectedModelId = currentModelId
            } else {
                selectedModelId =
                    currentProvider.models.first(where: \.recommended)?.id
                    ?? currentProvider.models.first?.id
                    ?? ""
            }
            return
        }

        guard
            let fallbackProvider =
                registry.provider(id: registry.defaultProvider)
                ?? registry.providers.first(where: \.available)
                ?? registry.providers.first
        else {
            selectedProviderId = ""
            selectedModelId = ""
            return
        }
        selectProvider(fallbackProvider)
    }

    private func selectProvider(_ provider: ChatAgentModelProviderInfo) {
        guard provider.available else { return }
        selectedProviderId = provider.id
        if provider.id == currentProviderId,
            provider.models.contains(where: { $0.id == currentModelId })
        {
            selectedModelId = currentModelId
        } else {
            selectedModelId =
                provider.models.first(where: \.recommended)?.id
                ?? provider.models.first?.id
                ?? ""
        }
    }

    private func saveSelection() {
        guard selectedPairIsValid, !isSaving else { return }
        isSaving = true
        onSave(selectedProviderId, selectedModelId) { success in
            isSaving = false
            if success {
                dismiss()
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

    @State private var image: UIImage?
    @State private var loadedUrl: String?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .onAppear { loadInitial() }
        .onChange(of: avatarUrl) { _ in
            Task { await loadImage() }
        }
    }

    private func loadInitial() {
        if let avatarUrl, let cached = ChatAvatarImageStore.cached(for: avatarUrl) {
            image = cached
            loadedUrl = avatarUrl
        } else {
            Task { await loadImage() }
        }
    }

    @MainActor
    private func loadImage() async {
        guard let url = avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            image = nil
            loadedUrl = nil
            return
        }
        if let fetched = await ChatAvatarImageStore.load(from: url) {
            if loadedUrl != url {
                image = fetched
                loadedUrl = url
            }
        }
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

// MARK: - Group VoIP / AI agent configuration sheet
// Presented as a pageSheet (same API as AgentBridgeHistorySheet / connect sheets):
// summary root + inner NavigationLink pushes — not one long full-screen form.

final class GroupAgentConfigModel: ObservableObject {
  let chatId: String
  let existingId: Any?
  let documents: [(id: String, name: String, url: String)]

  @Published var name: String
  @Published var systemPrompt: String
  @Published var enabled: Bool
  @Published var enabledTools: Set<String>
  @Published var generateInput: String = ""
  @Published var isGenerating = false
  @Published var errorMessage: String?

  var onSave: (([String: Any]) -> Void)?
  var onDelete: (() -> Void)?

  static let toolOptions: [(id: String, title: String, subtitle: String)] = [
    ("search_google", "Web Search", "Search Google for up-to-date results"),
    ("analyze_image", "Image Analysis", "Understand images and OCR text"),
    ("analyze_document", "Document Analysis", "Read and summarize document files"),
    ("create_document", "Create Document", "Generate formatted document drafts"),
  ]

  init(
    chatId: String,
    config: [String: Any]?,
    documents: [(id: String, name: String, url: String)] = []
  ) {
    self.chatId = chatId
    self.existingId = config?["id"]
    self.documents = documents
    self.name = (config?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let snake = (config?["system_prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let camel = (config?["systemPrompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.systemPrompt = snake.isEmpty ? camel : snake
    if let raw = config?["enabled"] as? Bool {
      self.enabled = raw
    } else if let n = config?["enabled"] as? NSNumber {
      self.enabled = n.boolValue
    } else {
      self.enabled = true
    }
    let tools =
      Self.parseTools(config?["enabled_tools"])
      ?? Self.parseTools(config?["enabledTools"])
      ?? ["search_google", "analyze_image", "analyze_document", "create_document"]
    self.enabledTools = Set(tools)
  }

  var isExisting: Bool { existingId != nil }

  var promptSummary: String {
    let p = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    return p.isEmpty ? "Not set" : p
  }

  var toolsSummary: String {
    switch enabledTools.count {
    case 0: return "None"
    case 1: return "1 tool"
    default: return "\(enabledTools.count) tools"
    }
  }

  func buildConfig() -> [String: Any]? {
    let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      errorMessage = "System prompt is required."
      return nil
    }
    guard !enabledTools.isEmpty else {
      errorMessage = "Enable at least one tool."
      return nil
    }
    errorMessage = nil
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var config: [String: Any] = [
      "chat_id": chatId,
      "name": trimmedName.isEmpty ? "Vibe AI" : trimmedName,
      "system_prompt": prompt,
      "enabled": enabled,
      "enabled_tools": Array(enabledTools).sorted(),
    ]
    if let existingId {
      config["id"] = existingId
    }
    return config
  }

  func generatePrompt(completion: @escaping (Bool) -> Void) {
    let input = generateInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else {
      errorMessage = "Describe the agent first."
      completion(false)
      return
    }
    guard !enabledTools.isEmpty else {
      errorMessage = "Enable at least one tool before generating."
      completion(false)
      return
    }
    isGenerating = true
    errorMessage = nil
    ChatEngine.shared.generateAgentPrompt(
      chatId: chatId,
      input: input,
      enabledTools: Array(enabledTools)
    ) { [weak self] payload in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isGenerating = false
        let generated =
          (payload?["systemPrompt"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !generated.isEmpty else {
          self.errorMessage = "Could not generate a prompt. Try adjusting your input."
          completion(false)
          return
        }
        self.systemPrompt = generated
        completion(true)
      }
    }
  }

  private static func parseTools(_ raw: Any?) -> [String]? {
    guard let list = raw as? [Any] else { return nil }
    let out = list.compactMap { item -> String? in
      if let s = item as? String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
      }
      if let n = item as? NSNumber { return n.stringValue }
      return nil
    }
    return out.isEmpty ? nil : out
  }
}

/// Clean pageSheet for group agent config — summary + inner pushes.
struct GroupAgentConfigSheet: View {
  @StateObject var model: GroupAgentConfigModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var showDeleteConfirm = false

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }
  /// Soft elevated row over glass — mirrors ask/progress sheet `neutralFill`.
  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
  }
  private var accentTint: Color { palette.text }

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack {
            Text("Name")
              .font(.system(size: 16, weight: .regular))
              .foregroundStyle(palette.text)
            Spacer(minLength: 12)
            TextField("Vibe AI", text: $model.name)
              .multilineTextAlignment(.trailing)
              .foregroundStyle(palette.secondaryText)
          }
          .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
          .listRowBackground(rowFill)

          Toggle("Agent Enabled", isOn: $model.enabled)
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
            .listRowBackground(rowFill)
        } header: {
          Text("Agent")
            .font(.system(size: 13, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(palette.secondaryText)
        } footer: {
          Text("When enabled, the agent can participate in this group chat.")
            .foregroundStyle(palette.secondaryText)
        }

        Section {
          NavigationLink {
            GroupAgentPromptEditor(model: model)
          } label: {
            configRow(title: "System Prompt", value: model.promptSummary)
          }
          .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
          .listRowBackground(rowFill)

          NavigationLink {
            GroupAgentToolsEditor(model: model)
          } label: {
            configRow(title: "Tools", value: model.toolsSummary)
          }
          .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
          .listRowBackground(rowFill)

          if !model.documents.isEmpty {
            NavigationLink {
              GroupAgentDocumentsView(documents: model.documents)
            } label: {
              configRow(title: "Documents", value: "\(model.documents.count)")
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
            .listRowBackground(rowFill)
          }
        } header: {
          Text("Configuration")
            .font(.system(size: 13, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(palette.secondaryText)
        }

        if model.isExisting {
          Section {
            Button("Remove Agent", role: .destructive) {
              showDeleteConfirm = true
            }
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 20))
            .listRowBackground(rowFill)
          }
        }

        if let errorMessage = model.errorMessage {
          Section {
            Text(errorMessage)
              .font(.system(size: 13))
              .foregroundStyle(.red)
              .listRowBackground(rowFill)
          }
        }
      }
      .listStyle(.insetGrouped)
      // Glass sheet body like chat progress/ask sheets — no solid fill.
      .scrollContentBackground(.hidden)
      .background(Color.clear)
      .navigationTitle("Vibe AI")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.hidden, for: .navigationBar)
      .tint(accentTint)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 15, weight: .semibold))
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(model.isExisting ? "Save" : "Create") {
            guard let config = model.buildConfig() else { return }
            model.onSave?(config)
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
      .confirmationDialog(
        "Remove AI Agent",
        isPresented: $showDeleteConfirm,
        titleVisibility: .visible
      ) {
        Button("Remove", role: .destructive) {
          model.onDelete?()
          dismiss()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This removes the agent and clears its memory. This cannot be undone.")
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    // Let the system pageSheet Liquid Glass show through (same as ask/progress sheets).
    .presentationBackground(.clear)
  }

  @ViewBuilder
  private func configRow(title: String, value: String) -> some View {
    HStack(spacing: 12) {
      Text(title)
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(palette.text)
      Spacer(minLength: 12)
      Text(value)
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(palette.secondaryText)
        .lineLimit(1)
    }
  }
}

private struct GroupAgentPromptEditor: View {
  @ObservedObject var model: GroupAgentConfigModel
  @Environment(\.colorScheme) private var colorScheme

  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
  }

  var body: some View {
    Form {
      Section {
        TextField("e.g. Helpful PM for sprint planning", text: $model.generateInput)
          .listRowBackground(rowFill)
        Button {
          model.generatePrompt { _ in }
        } label: {
          HStack {
            if model.isGenerating {
              ProgressView().controlSize(.small)
            }
            Text(model.isGenerating ? "Generating…" : "Generate from input")
          }
        }
        .disabled(model.isGenerating)
        .listRowBackground(rowFill)
      } header: {
        Text("Generate")
      } footer: {
        Text("Optional: describe the agent, then generate a system prompt.")
      }

      Section {
        TextEditor(text: $model.systemPrompt)
          .frame(minHeight: 220)
          .listRowBackground(rowFill)
      } header: {
        Text("System Prompt")
      } footer: {
        Text("Describe how this agent should behave in the group.")
      }
    }
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("System Prompt")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
  }
}

private struct GroupAgentToolsEditor: View {
  @ObservedObject var model: GroupAgentConfigModel
  @Environment(\.colorScheme) private var colorScheme

  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
  }

  var body: some View {
    List {
      Section {
        ForEach(GroupAgentConfigModel.toolOptions, id: \.id) { option in
          Toggle(isOn: Binding(
            get: { model.enabledTools.contains(option.id) },
            set: { on in
              if on {
                model.enabledTools.insert(option.id)
              } else {
                model.enabledTools.remove(option.id)
              }
            }
          )) {
            VStack(alignment: .leading, spacing: 2) {
              Text(option.title)
              Text(option.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
          }
          .listRowBackground(rowFill)
        }
      } header: {
        Text("Enabled Tools")
      } footer: {
        Text("At least one tool is required.")
      }
    }
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Tools")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
  }
}

private struct GroupAgentDocumentsView: View {
  let documents: [(id: String, name: String, url: String)]
  @Environment(\.colorScheme) private var colorScheme

  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
  }

  var body: some View {
    List {
      Section {
        ForEach(documents, id: \.id) { doc in
          Button {
            let cleaned = doc.url.replacingOccurrences(of: "vibe://", with: "https://")
            if let url = URL(string: cleaned) {
              UIApplication.shared.open(url)
            }
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "doc.text.fill")
                .foregroundStyle(.tint)
              Text(doc.name)
                .foregroundStyle(.primary)
              Spacer()
              Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            }
          }
          .listRowBackground(rowFill)
        }
      } header: {
        Text("Agent Documents")
      }
    }
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .navigationTitle("Documents")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
  }
}
