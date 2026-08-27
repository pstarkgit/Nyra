import Foundation
import Testing
@testable import CodexVoice

@MainActor
@Test func refreshRestoresPersistedTaskSelection() async throws {
    let preferences = MemoryPreferences(values: [
        AppPreferenceKey.selectedTaskID: "thread-2",
    ])
    let codex = AppModelCodex(tasks: [.first, .second])
    let coordinator = makeCoordinator(codex: codex)
    let model = AppModel(
        codex: codex,
        coordinator: coordinator,
        preferences: preferences
    )

    await model.connectAndRefresh()

    #expect(model.connectionStatus == .connected)
    #expect(model.selectedTask?.id == "thread-2")
    #expect(model.tasks.map(\.id) == ["thread-1", "thread-2"])
}

@MainActor
@Test func refreshSelectsFirstTaskWhenPersistedTaskIsMissing() async throws {
    let preferences = MemoryPreferences(values: [
        AppPreferenceKey.selectedTaskID: "removed",
    ])
    let codex = AppModelCodex(tasks: [.first, .second])
    let model = AppModel(
        codex: codex,
        coordinator: makeCoordinator(codex: codex),
        preferences: preferences
    )

    await model.connectAndRefresh()

    #expect(model.selectedTaskID == "thread-1")
    #expect(preferences.values[AppPreferenceKey.selectedTaskID] == "thread-1")
}

@MainActor
@Test func selectingTaskPersistsOnlyIdentifier() async throws {
    let preferences = MemoryPreferences()
    let codex = AppModelCodex(tasks: [.first, .second])
    let model = AppModel(
        codex: codex,
        coordinator: makeCoordinator(codex: codex),
        preferences: preferences
    )
    await model.connectAndRefresh()

    model.selectTask(id: "thread-2")

    #expect(preferences.values == [
        AppPreferenceKey.selectedTaskID: "thread-2",
    ])
}

@MainActor
@Test func connectionFailureIsVisibleAndDoesNotInferEmptyAsHealthy() async {
    let codex = AppModelCodex(tasks: [], failure: AppModelTestError.offline)
    let model = AppModel(
        codex: codex,
        coordinator: makeCoordinator(codex: codex),
        preferences: MemoryPreferences()
    )

    await model.connectAndRefresh()

    #expect(model.connectionStatus == .failed("Codex is offline"))
    #expect(model.tasks.isEmpty)
}

@Test func rightOptionDecisionTogglesOnlyOnPhysicalDownEdge() {
    var decision = RightOptionHotkeyDecision.evaluate(
        keyCode: 61,
        alternateDown: true,
        wasDown: false
    )
    #expect(decision == .init(isDown: true, shouldToggle: true))

    decision = RightOptionHotkeyDecision.evaluate(
        keyCode: 61,
        alternateDown: true,
        wasDown: true
    )
    #expect(decision == .init(isDown: true, shouldToggle: false))

    decision = RightOptionHotkeyDecision.evaluate(
        keyCode: 61,
        alternateDown: false,
        wasDown: true
    )
    #expect(decision == .init(isDown: false, shouldToggle: false))

    #expect(RightOptionHotkeyDecision.evaluate(
        keyCode: 58,
        alternateDown: true,
        wasDown: false
    ) == .init(isDown: false, shouldToggle: false))
}

private actor AppModelCodex: CodexServing {
    let tasks: [CodexTask]
    let failure: Error?
    private let stream = AsyncStream<CodexServerEvent> { $0.finish() }

    init(tasks: [CodexTask], failure: Error? = nil) {
        self.tasks = tasks
        self.failure = failure
    }

    func connect() async throws {
        if let failure { throw failure }
    }
    func listTasks(limit: Int) async throws -> [CodexTask] {
        if let failure { throw failure }
        return tasks
    }
    func resumeTask(id: String) async throws {}
    func forkTask(id: String) async throws -> String { id }
    func startTask(cwd: String) async throws -> String { idForStart }

    private var idForStart: String { tasks.first?.id ?? "thread-1" }
    func startTurn(threadId: String, text: String) async throws -> String { "turn" }
    func steerTurn(threadId: String, text: String) async throws {}
    func interruptTurn(threadId: String, turnId: String) async throws {}
    func answerApproval(id: RequestID, decision: ApprovalDecision) async throws {}
    func events() async -> AsyncStream<CodexServerEvent> { stream }
    func shutdown() async {}
}

@MainActor
private func makeCoordinator(codex: CodexServing) -> ConversationCoordinator {
    ConversationCoordinator(
        codex: codex,
        capture: AppModelCapture(),
        synthesizer: AppModelSynthesizer()
    )
}

@MainActor
private final class AppModelCapture: SpeechCapturing {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onSpeechStarted: (() -> Void)?
    var onLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?
    var isCapturing = false
    func start() throws { isCapturing = true }
    func finishUtterance() { isCapturing = false }
    func cancel() { isCapturing = false }
}

@MainActor
private final class AppModelSynthesizer: SpeechSynthesizing {
    var isSpeaking = false
    func speak(_ text: String) async {}
    func stop() {}
}

private final class MemoryPreferences: PreferenceStoring {
    var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func string(forKey defaultName: String) -> String? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value as? String
    }
}

private extension CodexTask {
    static let first = CodexTask(
        id: "thread-1", title: "First", cwd: "/tmp/one", updatedAt: 2, status: "idle"
    )
    static let second = CodexTask(
        id: "thread-2", title: "Second", cwd: "/tmp/two", updatedAt: 1, status: "idle"
    )
}

private enum AppModelTestError: LocalizedError {
    case offline
    var errorDescription: String? { "Codex is offline" }
}
