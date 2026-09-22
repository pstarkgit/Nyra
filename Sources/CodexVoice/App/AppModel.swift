import Combine
import Foundation

enum AppPreferenceKey {
    static let selectedTaskID = "selectedTaskID"
    static let selectedVoiceIdentifier = "selectedVoiceIdentifier"
    static let speechOutputProvider = "speechOutputProvider"
    static let selectedPollyVoiceID = "selectedPollyVoiceID"
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

    let coordinator: ConversationCoordinator
    private let codex: CodexServing
    private let preferences: PreferenceStoring

    var selectedTask: CodexTask? {
        tasks.first { $0.id == selectedTaskID }
    }

    init(
        codex: CodexServing,
        coordinator: ConversationCoordinator,
        preferences: PreferenceStoring = UserDefaults.standard
    ) {
        self.codex = codex
        self.coordinator = coordinator
        self.preferences = preferences
        selectedTaskID = preferences.string(forKey: AppPreferenceKey.selectedTaskID)
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

    func toggleSession() async {
        if coordinator.state == .idle {
            guard let selectedTask else { return }
            do {
                try await coordinator.startSession(task: selectedTask)
            } catch {
                connectionStatus = .failed(error.localizedDescription)
            }
        } else {
            coordinator.endSession()
        }
    }

    func handleHotkey() async {
        switch coordinator.state {
        case .idle:
            await toggleSession()
        case .speaking:
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
