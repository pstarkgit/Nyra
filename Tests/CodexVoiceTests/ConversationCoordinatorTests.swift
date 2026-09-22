import Foundation
import Testing
@testable import CodexVoice

@MainActor
@Test func finalTranscriptRunsTurnSpeaksAndListensAgain() async throws {
    let harness = CoordinatorHarness()
    try await harness.coordinator.startSession(task: .fixture)
    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("What changed?")
    try await waitUntil { harness.coordinator.state == .waitingForCodex }

    await harness.codex.emit(.agentDelta(
        threadID: "thread-1",
        turnID: "turn-1",
        text: "The fix is installed."
    ))
    await harness.codex.emit(.turnCompleted(
        threadID: "thread-1",
        turnID: "turn-1",
        status: "completed"
    ))
    try await waitUntil { harness.synthesizer.spoken == ["The fix is installed."] }
    harness.synthesizer.finish()
    try await waitUntil { harness.coordinator.state == .listening }

    #expect(harness.capture.startCalls == 2)
    #expect(await harness.codex.startedTexts.count == 1)
    #expect(await harness.codex.startedTexts[0].contains("What changed?"))
}

@MainActor
@Test func postSpeechCooldownKeepsMicrophoneClosedUntilOutputClears() async throws {
    let harness = CoordinatorHarness(postSpeechDelay: .milliseconds(150))
    try await harness.coordinator.startSession(task: .fixture)
    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("What changed?")
    try await waitUntil { harness.coordinator.canSteer }
    await harness.codex.emit(.agentDelta(
        threadID: "thread-1",
        turnID: "turn-1",
        text: "Done."
    ))
    await harness.codex.emit(.turnCompleted(
        threadID: "thread-1",
        turnID: "turn-1",
        status: "completed"
    ))
    try await waitUntil { harness.synthesizer.spoken == ["Done."] }

    harness.synthesizer.finish()
    await Task.yield()

    #expect(harness.coordinator.state == .speaking)
    #expect(harness.capture.startCalls == 1)
    try await waitUntil { harness.coordinator.state == .listening }
    #expect(harness.capture.startCalls == 2)
}

@MainActor
@Test func sentenceSpeechStartsBeforeCompletionAndFlushesFinalFragmentInOrder() async throws {
    let harness = CoordinatorHarness()
    try await harness.coordinator.startSession(task: .fixture)
    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("Explain the result")
    try await waitUntil { harness.coordinator.canSteer }

    await harness.codex.emit(.agentDelta(
        threadID: "thread-1",
        turnID: "turn-1",
        text: "First sentence. Final"
    ))
    try await waitUntil { harness.synthesizer.spoken == ["First sentence."] }

    #expect(harness.coordinator.state == .waitingForCodex)
    #expect(harness.coordinator.latestResponse.isEmpty)
    #expect(harness.capture.startCalls == 1)

    await harness.codex.emit(.agentDelta(
        threadID: "thread-1",
        turnID: "turn-1",
        text: " fragment"
    ))
    await harness.codex.emit(.turnCompleted(
        threadID: "thread-1",
        turnID: "turn-1",
        status: "completed"
    ))
    try await waitUntil {
        harness.coordinator.latestResponse == "First sentence. Final fragment"
    }

    harness.synthesizer.finish()
    try await waitUntil {
        harness.synthesizer.spoken == ["First sentence.", "Final fragment"]
    }
    #expect(harness.coordinator.state == .speaking)
    #expect(harness.capture.startCalls == 1)

    harness.synthesizer.finish()
    try await waitUntil { harness.coordinator.state == .listening }

    #expect(harness.coordinator.latestResponse == "First sentence. Final fragment")
    #expect(harness.capture.startCalls == 2)
}

@MainActor
@Test func earlySpeechInterruptionCancelsQueueAndPreservesTranscript() async throws {
    let harness = CoordinatorHarness()
    try await harness.coordinator.startSession(task: .fixture)
    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("Explain the result")
    try await waitUntil { harness.coordinator.canSteer }

    await harness.codex.emit(.agentDelta(
        threadID: "thread-1",
        turnID: "turn-1",
        text: "First sentence. Queued sentence."
    ))
    try await waitUntil { harness.synthesizer.spoken == ["First sentence."] }

    harness.coordinator.interruptPlayback()
    await harness.codex.emit(.agentDelta(
        threadID: "thread-1",
        turnID: "turn-1",
        text: " Later sentence."
    ))
    await harness.codex.emit(.turnCompleted(
        threadID: "thread-1",
        turnID: "turn-1",
        status: "completed"
    ))
    try await waitUntil { harness.coordinator.state == .listening }

    #expect(harness.synthesizer.spoken == ["First sentence."])
    #expect(harness.synthesizer.stopCalls == 1)
    #expect(harness.coordinator.latestResponse
        == "First sentence. Queued sentence. Later sentence.")
    #expect(harness.capture.startCalls == 2)
}

@MainActor
@Test func explicitTurnCancellationStopsStreamingSpeech() async throws {
    let harness = CoordinatorHarness()
    try await harness.coordinator.startSession(task: .fixture)
    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("Start work")
    try await waitUntil { harness.coordinator.canSteer }

    await harness.codex.emit(.agentDelta(
        threadID: "thread-1",
        turnID: "turn-1",
        text: "Started sentence. Queued sentence."
    ))
    try await waitUntil { harness.synthesizer.spoken == ["Started sentence."] }

    try await harness.coordinator.cancelActiveTurn()
    await harness.codex.emit(.turnCompleted(
        threadID: "thread-1",
        turnID: "turn-1",
        status: "cancelled"
    ))
    try await waitUntil { harness.coordinator.state == .listening }

    #expect(await harness.codex.interruptedTurns == ["turn-1"])
    #expect(harness.synthesizer.spoken == ["Started sentence."])
    #expect(harness.synthesizer.stopCalls == 1)
    #expect(harness.coordinator.latestResponse.isEmpty)
}

@MainActor
@Test func sessionEndCancelsStreamingSpeechWithoutRestartingCapture() async throws {
    let harness = CoordinatorHarness()
    try await harness.coordinator.startSession(task: .fixture)
    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("Start work")
    try await waitUntil { harness.coordinator.canSteer }

    await harness.codex.emit(.agentDelta(
        threadID: "thread-1",
        turnID: "turn-1",
        text: "Speaking now. Never play this."
    ))
    try await waitUntil { harness.synthesizer.spoken == ["Speaking now."] }

    harness.coordinator.endSession()
    try await waitUntil { harness.coordinator.state == .idle }

    #expect(harness.synthesizer.spoken == ["Speaking now."])
    #expect(harness.synthesizer.stopCalls == 1)
    #expect(harness.capture.startCalls == 1)
    #expect(harness.coordinator.selectedTask == nil)
}

@MainActor
@Test func failedTurnCancelsEarlySpeechAndReturnsToListening() async throws {
    let harness = CoordinatorHarness()
    try await harness.coordinator.startSession(task: .fixture)
    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("Start work")
    try await waitUntil { harness.coordinator.canSteer }

    await harness.codex.emit(.agentDelta(
        threadID: "thread-1",
        turnID: "turn-1",
        text: "Partial result. Must not play."
    ))
    try await waitUntil { harness.synthesizer.spoken == ["Partial result."] }
    await harness.codex.emit(.turnCompleted(
        threadID: "thread-1",
        turnID: "turn-1",
        status: "failed"
    ))
    try await waitUntil { harness.coordinator.state == .listening }

    #expect(harness.synthesizer.spoken == ["Partial result."])
    #expect(harness.synthesizer.stopCalls == 1)
    #expect(harness.coordinator.latestResponse.isEmpty)
    #expect(harness.capture.startCalls == 2)
}

@MainActor
@Test func recentSpokenReplyIsDiscardedAsSpeakerEcho() async throws {
    let harness = CoordinatorHarness()
    try await harness.coordinator.startSession(task: .fixture)
    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("What changed?")
    try await waitUntil { harness.coordinator.canSteer }
    await harness.codex.emit(.agentDelta(
        threadID: "thread-1",
        turnID: "turn-1",
        text: "The voice threshold is fixed."
    ))
    await harness.codex.emit(.turnCompleted(
        threadID: "thread-1",
        turnID: "turn-1",
        status: "completed"
    ))
    try await waitUntil { harness.synthesizer.spoken.count == 1 }
    harness.synthesizer.finish()
    try await waitUntil { harness.coordinator.state == .listening }

    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("voice threshold fixed")
    try await Task.sleep(for: .milliseconds(50))

    #expect(await harness.codex.startedTexts.count == 1)
    #expect(harness.coordinator.state == .listening)
}

@MainActor
@Test func emptyTranscriptReturnsToListeningWithoutCodexTurn() async throws {
    let harness = CoordinatorHarness()
    try await harness.coordinator.startSession(task: .fixture)
    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("   ")
    try await waitUntil { harness.coordinator.state == .listening }

    #expect(await harness.codex.startedTexts.isEmpty)
    #expect(harness.capture.startCalls == 2)
}

@MainActor
@Test func localEndCommandStopsSessionWithoutSendingTurn() async throws {
    let harness = CoordinatorHarness()
    try await harness.coordinator.startSession(task: .fixture)
    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("end voice session")
    try await waitUntil { harness.coordinator.state == .idle }

    #expect(await harness.codex.startedTexts.isEmpty)
    #expect(harness.capture.cancelCalls == 1)
}

@MainActor
@Test func approvalPausesUntilVisibleDecision() async throws {
    let harness = CoordinatorHarness()
    try await harness.coordinator.startSession(task: .fixture)
    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("Run the check")
    try await waitUntil { harness.coordinator.state == .waitingForCodex }
    let approval = CodexApproval(
        id: .string("approval-1"),
        kind: .command,
        summary: "Run command",
        details: "swift test"
    )

    await harness.codex.emit(.approvalRequested(approval))
    try await waitUntil { harness.coordinator.state == .awaitingApproval }
    try await harness.coordinator.answerApproval(.decline)

    #expect(harness.coordinator.state == .waitingForCodex)
    #expect(harness.coordinator.activeApproval == nil)
    #expect(await harness.codex.approvalDecisions == [.decline])
}

@MainActor
@Test func interruptedTurnDoesNotSpeakStaleText() async throws {
    let harness = CoordinatorHarness()
    try await harness.coordinator.startSession(task: .fixture)
    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("Start work")
    try await waitUntil { harness.coordinator.canSteer }
    await harness.codex.emit(.agentDelta(
        threadID: "thread-1",
        turnID: "turn-1",
        text: "stale answer"
    ))
    await harness.codex.emit(.turnCompleted(
        threadID: "thread-1",
        turnID: "turn-1",
        status: "interrupted"
    ))
    try await waitUntil { harness.coordinator.state == .listening }

    #expect(harness.synthesizer.spoken.isEmpty)
    #expect(harness.coordinator.latestResponse.isEmpty)
}

@MainActor
@Test func activeTurnCanBeSteeredByAnotherUtterance() async throws {
    let harness = CoordinatorHarness()
    try await harness.coordinator.startSession(task: .fixture)
    harness.capture.emitSpeechStarted()
    harness.capture.emitFinal("Start work")
    try await waitUntil { harness.coordinator.canSteer }

    try harness.coordinator.beginListeningForSteer()
    harness.capture.emitFinal("Focus on the tests")
    try await waitUntil { await harness.codex.steeredTexts.count == 1 }

    #expect(harness.coordinator.state == .waitingForCodex)
    #expect(await harness.codex.steeredTexts == ["Focus on the tests"])
}

@MainActor
private final class CoordinatorHarness {
    let codex = FakeCodexServer()
    let capture = FakeSpeechCapture()
    let synthesizer = FakeSpeechSynthesizer()
    private let postSpeechDelay: Duration

    init(postSpeechDelay: Duration = .zero) {
        self.postSpeechDelay = postSpeechDelay
    }

    lazy var coordinator = ConversationCoordinator(
        codex: codex,
        capture: capture,
        synthesizer: synthesizer,
        formatter: SpokenResponseFormatter(maximumCharacters: 500),
        postSpeechDelay: postSpeechDelay
    )
}

private actor FakeCodexServer: CodexServing {
    private let stream: AsyncStream<CodexServerEvent>
    private let continuation: AsyncStream<CodexServerEvent>.Continuation
    var startedTexts: [String] = []
    var steeredTexts: [String] = []
    var approvalDecisions: [ApprovalDecision] = []
    var interruptedTurns: [String] = []

    init() {
        var continuation: AsyncStream<CodexServerEvent>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {}
    func listTasks(limit: Int) async throws -> [CodexTask] { [.fixture] }
    func resumeTask(id: String) async throws {}
    func forkTask(id: String) async throws -> String { id }
    func startTask(cwd: String, model: String?) async throws -> String { "thread-1" }
    func startTurn(threadId: String, text: String) async throws -> String {
        startedTexts.append(text)
        return "turn-1"
    }
    func steerTurn(threadId: String, text: String) async throws {
        steeredTexts.append(text)
    }
    func interruptTurn(threadId: String, turnId: String) async throws {
        interruptedTurns.append(turnId)
    }
    func answerApproval(id: RequestID, decision: ApprovalDecision) async throws {
        approvalDecisions.append(decision)
    }
    func events() async -> AsyncStream<CodexServerEvent> { stream }
    func shutdown() async { continuation.finish() }
    func emit(_ event: CodexServerEvent) { continuation.yield(event) }
}

@MainActor
private final class FakeSpeechCapture: SpeechCapturing {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onSpeechStarted: (() -> Void)?
    var onLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var isCapturing = false
    var startCalls = 0
    var cancelCalls = 0

    func start() throws {
        startCalls += 1
        isCapturing = true
    }
    func finishUtterance() { isCapturing = false }
    func cancel() {
        cancelCalls += 1
        isCapturing = false
    }
    func emitSpeechStarted() { onSpeechStarted?() }
    func emitFinal(_ text: String) {
        isCapturing = false
        onFinal?(text)
    }
}

@MainActor
private final class FakeSpeechSynthesizer: SpeechSynthesizing {
    private(set) var isSpeaking = false
    var spoken: [String] = []
    private(set) var stopCalls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func speak(_ text: String) async {
        isSpeaking = true
        spoken.append(text)
        await withCheckedContinuation { continuation = $0 }
    }
    func stop() {
        stopCalls += 1
        finish()
    }
    func finish() {
        isSpeaking = false
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private extension CodexTask {
    static let fixture = CodexTask(
        id: "thread-1",
        title: "Fixture",
        cwd: "/tmp/project",
        updatedAt: 1,
        status: "idle"
    )
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !(await condition()) {
        if ContinuousClock.now >= deadline {
            throw CoordinatorTestError.timeout
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private enum CoordinatorTestError: Error {
    case timeout
}
