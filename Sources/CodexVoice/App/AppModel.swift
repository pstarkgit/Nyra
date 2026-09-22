import Combine
import Foundation

enum AppPreferenceKey {
    static let selectedTaskID = "selectedTaskID"
    static let selectedVoiceIdentifier = "selectedVoiceIdentifier"
    static let speechOutputProvider = "speechOutputProvider"
    static let selectedPollyVoiceID = "selectedPollyVoiceID"
    static let selectedVoiceModelID = "selectedVoiceModelID"
    static let selectedInputDeviceUID = "selectedInputDeviceUID"
    static let selectedInputDeviceName = "selectedInputDeviceName"
    static let conversationEngine = "conversationEngine"
    static let selectedNovaVoiceID = "selectedNovaVoiceID"
}

struct VoiceModelOption: Identifiable, Equatable, Sendable {
    let id: String
    let label: String

    static let supported = [
        VoiceModelOption(id: "openai.gpt-5.6-luna", label: "Luna · Fast"),
        VoiceModelOption(id: "openai.gpt-5.6-terra", label: "Terra · Balanced"),
        VoiceModelOption(id: "openai.gpt-5.6-sol", label: "Sol · Deep"),
    ]
}

enum ConversationEngineOption: String, CaseIterable, Identifiable, Sendable {
    case naturalRealtime = "natural-realtime-nova-2-sonic"
    case codexAgent = "codex-agent-task-aware"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .naturalRealtime: return "Natural Realtime · Nova 2 Sonic"
        case .codexAgent: return "Codex Agent · Task-aware (slower)"
        }
    }
}

protocol PreferenceStoring: AnyObject {
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferenceStoring {}

enum AppConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var selectedTaskID: String?
    @Published private(set) var connectionStatus: AppConnectionStatus = .disconnected
    @Published private(set) var isRefreshing = false
    @Published private(set) var selectedVoiceModelID: String
    @Published private(set) var selectedConversationEngine: ConversationEngineOption
    @Published private(set) var selectedNovaVoiceID: String

    let coordinator: ConversationCoordinator
    let nova: NovaConversationController?
    private let codex: CodexServing
    private let preferences: PreferenceStoring

    var selectedTask: CodexTask? {
        tasks.first { $0.id == selectedTaskID }
    }

    var isSessionActive: Bool {
        switch selectedConversationEngine {
        case .naturalRealtime: return nova?.state.isActive ?? false
        case .codexAgent: return coordinator.state != .idle
        }
    }

    init(
        codex: CodexServing,
        coordinator: ConversationCoordinator,
        nova: NovaConversationController? = nil,
        preferences: PreferenceStoring = UserDefaults.standard
    ) {
        self.codex = codex
        self.coordinator = coordinator
        self.nova = nova
        self.preferences = preferences
        selectedTaskID = preferences.string(forKey: AppPreferenceKey.selectedTaskID)
        if let persistedModel = preferences.string(
            forKey: AppPreferenceKey.selectedVoiceModelID
        ), VoiceModelOption.supported.contains(where: { $0.id == persistedModel }) {
            selectedVoiceModelID = persistedModel
        } else {
            selectedVoiceModelID = "openai.gpt-5.6-terra"
        }
        selectedConversationEngine = ConversationEngineOption(rawValue:
            preferences.string(forKey: AppPreferenceKey.conversationEngine) ?? ""
        ) ?? .naturalRealtime
        let persistedVoice = preferences.string(forKey: AppPreferenceKey.selectedNovaVoiceID)
        selectedNovaVoiceID = NovaSonicVoice.supported.contains(where: {
            $0.id == persistedVoice
        }) ? persistedVoice! : NovaSonicVoice.defaultVoice.id
    }

    func connectAndRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        connectionStatus = .connecting
        defer { isRefreshing = false }
        do {
            try await codex.connect()
            let loaded = try await codex.listTasks(limit: 100)
            tasks = loaded.sorted { $0.updatedAt > $1.updatedAt }
            if selectedTask == nil {
                setSelectedTaskID(tasks.first?.id)
            }
            connectionStatus = .connected
        } catch {
            tasks = []
            connectionStatus = .failed(error.localizedDescription)
        }
    }

    func selectTask(id: String) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        setSelectedTaskID(id)
    }

    func selectVoiceModel(id: String) {
        guard VoiceModelOption.supported.contains(where: { $0.id == id }) else { return }
        selectedVoiceModelID = id
        preferences.set(id, forKey: AppPreferenceKey.selectedVoiceModelID)
    }

    func selectConversationEngine(_ engine: ConversationEngineOption) {
        guard coordinator.state == .idle, !(nova?.state.isActive ?? false) else { return }
        selectedConversationEngine = engine
        preferences.set(engine.rawValue, forKey: AppPreferenceKey.conversationEngine)
    }

    func selectNovaVoice(id: String) {
        guard NovaSonicVoice.supported.contains(where: { $0.id == id }),
              !(nova?.state.isActive ?? false) else { return }
        selectedNovaVoiceID = id
        preferences.set(id, forKey: AppPreferenceKey.selectedNovaVoiceID)
    }

    func toggleSession() async {
        switch selectedConversationEngine {
        case .naturalRealtime:
            guard let nova else { return }
            if nova.state.isActive {
                await nova.end()
            } else {
                try? await nova.start(voiceID: selectedNovaVoiceID)
            }
        case .codexAgent:
            if coordinator.state == .idle {
                guard let selectedTask else { return }
                do {
                    try await coordinator.startSession(
                        task: selectedTask,
                        model: selectedVoiceModelID
                    )
                } catch {
                    connectionStatus = .failed(error.localizedDescription)
                }
            } else {
                coordinator.endSession()
            }
        }
    }

    func handleHotkey() async {
        if selectedConversationEngine == .naturalRealtime, let nova {
            switch nova.state {
            case .idle, .failed:
                await toggleSession()
            case .speaking, .responding:
                nova.interruptPlayback()
            case .connecting, .listening, .userSpeaking, .ending:
                await nova.end()
            }
            return
        }

        switch coordinator.state {
        case .idle:
            await toggleSession()
        case .speaking:
            coordinator.interruptPlayback()
        case .waitingForCodex where coordinator.isSpeechPlaying:
            coordinator.interruptPlayback()
        case .waitingForCodex where coordinator.canSteer:
            try? coordinator.beginListeningForSteer()
        case .listening, .transcribing, .failed:
            coordinator.endSession()
        case .waitingForCodex, .awaitingApproval, .ending:
            break
        }
    }

    func answerApproval(_ decision: ApprovalDecision) async {
        do {
            try await coordinator.answerApproval(decision)
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }

    func requestPermissions() async {
        _ = await AppleSpeechSession.requestMicrophonePermission()
        GlobalHotkey.requestAccessibility()
    }

    private func setSelectedTaskID(_ id: String?) {
        selectedTaskID = id
        preferences.set(id, forKey: AppPreferenceKey.selectedTaskID)
    }
}
