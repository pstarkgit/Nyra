import Combine
import Foundation

enum ConversationCoordinatorError: LocalizedError, Equatable {
    case sessionAlreadyActive
    case noActiveTask
    case noActiveTurn
    case noApproval
    case invalidState(ConversationState)

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyActive: return "A voice session is already active."
        case .noActiveTask: return "Select a Codex task first."
        case .noActiveTurn: return "There is no active Codex turn to steer."
        case .noApproval: return "There is no approval awaiting a decision."
        case .invalidState(let state): return "Voice session cannot do that from \(state)."
        }
    }
}

@MainActor
final class ConversationCoordinator: ObservableObject {
    @Published private(set) var state: ConversationState = .idle
    @Published private(set) var partialTranscript = ""
    @Published private(set) var latestResponse = ""
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var activeApproval: CodexApproval?
    @Published private(set) var selectedTask: CodexTask?
    @Published private(set) var lastError: String?

    var canSteer: Bool {
        state == .waitingForCodex && activeTurnID != nil
    }

    private let codex: CodexServing
    private let capture: SpeechCapturing
    private let synthesizer: SpeechSynthesizing
    private let formatter: SpokenResponseFormatter
    private let postSpeechDelay: Duration
    private var eventTask: Task<Void, Never>?
    private var activeTurnID: String?
    private var activeThreadID: String?
    private var responseBuffer = ""
    private var lastSpokenText = ""
    private var lastSpeechFinishedAt: ContinuousClock.Instant?
    private var generation: UInt64 = 0

    init(
        codex: CodexServing,
        capture: SpeechCapturing,
        synthesizer: SpeechSynthesizing,
        formatter: SpokenResponseFormatter = SpokenResponseFormatter(),
        postSpeechDelay: Duration = .milliseconds(1_800)
    ) {
        self.codex = codex
        self.capture = capture
        self.synthesizer = synthesizer
        self.formatter = formatter
        self.postSpeechDelay = postSpeechDelay
        bindCaptureCallbacks()
    }

    func startSession(task: CodexTask) async throws {
        guard state == .idle else {
            throw ConversationCoordinatorError.sessionAlreadyActive
        }
        try await codex.connect()
        activeThreadID = try await codex.startTask(cwd: task.cwd)
        selectedTask = task
        partialTranscript = ""
        latestResponse = ""
        lastError = nil
        responseBuffer = ""
        activeTurnID = nil
        lastSpokenText = ""
        lastSpeechFinishedAt = nil
        generation &+= 1
        startEventLoopIfNeeded()
        try transition(.startSession)
        try startCapture()
    }

    func endSession() {
        guard state != .idle else { return }
        generation &+= 1
        capture.cancel()
        synthesizer.stop()
        activeApproval = nil
        activeTurnID = nil
        activeThreadID = nil
        responseBuffer = ""
        partialTranscript = ""
        inputLevel = 0
        if (try? transition(.endSession)) != nil {
            try? transition(.sessionEnded)
        }
        selectedTask = nil
    }

    func shutdown() async {
        endSession()
        eventTask?.cancel()
        eventTask = nil
        await codex.shutdown()
    }

    func beginListeningForSteer() throws {
        guard activeTurnID != nil else {
            throw ConversationCoordinatorError.noActiveTurn
        }
        guard state == .waitingForCodex else {
            throw ConversationCoordinatorError.invalidState(state)
        }
        try transition(.beginSteering)
        try startCapture()
    }

    func interruptPlayback() {
        guard state == .speaking else { return }
        synthesizer.stop()
    }

    func cancelActiveTurn() async throws {
        guard let activeThreadID else {
            throw ConversationCoordinatorError.noActiveTask
        }
        guard let activeTurnID else {
            throw ConversationCoordinatorError.noActiveTurn
        }
        try await codex.interruptTurn(threadId: activeThreadID, turnId: activeTurnID)
    }

    func answerApproval(_ decision: ApprovalDecision) async throws {
        guard let approval = activeApproval else {
            throw ConversationCoordinatorError.noApproval
        }
        try await codex.answerApproval(id: approval.id, decision: decision)
        activeApproval = nil
        try transition(.approvalAnswered)
    }

    private func bindCaptureCallbacks() {
        capture.onPartial = { [weak self] text in
            self?.partialTranscript = text
        }
        capture.onLevel = { [weak self] level in
            self?.inputLevel = level
        }
        capture.onSpeechStarted = { [weak self] in
            guard let self, self.state == .listening else { return }
            try? self.transition(.speechDetected)
        }
        capture.onFinal = { [weak self] text in
            Task { @MainActor [weak self] in
                await self?.handleFinalTranscript(text)
            }
        }
        capture.onError = { [weak self] message in
            self?.fail(message)
        }
    }

    private func startEventLoopIfNeeded() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self, codex] in
            let stream = await codex.events()
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }

    private func handleFinalTranscript(_ rawText: String) async {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        partialTranscript = ""
        inputLevel = 0

        guard !text.isEmpty else {
            discardAndResumeListening()
            return
        }
        if isRecentSpeakerEcho(text) {
            discardAndResumeListening()
            return
        }
        if let command = LocalVoiceCommand.parse(text) {
            await handle(command)
            return
        }
        guard let activeThreadID else {
            fail(ConversationCoordinatorError.noActiveTask.localizedDescription)
            return
        }

        let steering = activeTurnID != nil
        do {
            try transition(.transcriptionFinalized)
            if steering {
                try await codex.steerTurn(threadId: activeThreadID, text: text)
            } else {
                responseBuffer = ""
                latestResponse = ""
                let prompt = """
                [Voice session: respond in concise spoken prose. Put code and long technical detail in files or the task transcript; finish with the outcome first.]

                \(text)
                """
                activeTurnID = try await codex.startTurn(
                    threadId: activeThreadID,
                    text: prompt
                )
                try transition(.turnStarted)
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func handle(_ command: LocalVoiceCommand) async {
        switch command {
        case .endSession:
            endSession()
        case .stopSpeaking:
            synthesizer.stop()
            discardAndResumeListening()
        case .cancelTurn:
            do {
                try transition(.transcriptionFinalized)
                try await cancelActiveTurn()
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func handle(_ event: CodexServerEvent) async {
        guard let activeThreadID else { return }
        switch event {
        case .agentDelta(let threadID, let turnID, let text):
            guard threadID == activeThreadID, turnID == activeTurnID else { return }
            responseBuffer += text
        case .approvalRequested(let approval):
            guard state == .waitingForCodex else { return }
            activeApproval = approval
            try? transition(.approvalRequested)
        case .turnCompleted(let threadID, let turnID, let status):
            guard threadID == activeThreadID, turnID == activeTurnID else { return }
            await finishTurn(status: status)
        case .error(let message):
            fail(message)
        case .disconnected:
            fail("Codex app-server disconnected; turn completion is unknown.")
        }
    }

    private func finishTurn(status: String) async {
        if state == .awaitingApproval {
            activeApproval = nil
            try? transition(.approvalAnswered)
        }
        activeTurnID = nil
        if status != "completed" {
            responseBuffer = ""
            latestResponse = ""
            if (try? transition(.turnCompleted)) != nil {
                try? transition(.speechFinished)
                try? startCapture()
            }
            return
        }

        latestResponse = responseBuffer
        responseBuffer = ""
        guard (try? transition(.turnCompleted)) != nil else { return }
        let spoken = formatter.format(latestResponse).text
        let currentGeneration = generation
        if !spoken.isEmpty {
            await synthesizer.speak(spoken)
            lastSpokenText = spoken
            lastSpeechFinishedAt = ContinuousClock.now
        }
        guard currentGeneration == generation, state == .speaking else { return }
        if postSpeechDelay > .zero {
            try? await Task.sleep(for: postSpeechDelay)
        }
        guard currentGeneration == generation, state == .speaking else { return }
        try? transition(.speechFinished)
        try? startCapture()
    }

    private func discardAndResumeListening() {
        if state == .transcribing {
            try? transition(.discardTranscript)
        }
        if state == .listening {
            try? startCapture()
        }
    }

    private func isRecentSpeakerEcho(_ transcript: String) -> Bool {
        guard let lastSpeechFinishedAt,
              lastSpeechFinishedAt.duration(to: ContinuousClock.now) <= .seconds(8)
        else { return false }
        let spokenWords = Self.significantWords(in: lastSpokenText)
        let transcriptWords = Self.significantWords(in: transcript)
        guard transcriptWords.count >= 2, !spokenWords.isEmpty else { return false }
        let overlap = transcriptWords.intersection(spokenWords).count
        return Double(overlap) / Double(transcriptWords.count) >= 0.60
    }

    private static func significantWords(in text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: .alphanumerics.inverted)
            .filter { $0.count >= 3 })
    }

    private func startCapture() throws {
        do {
            try capture.start()
        } catch {
            fail(error.localizedDescription)
            throw error
        }
    }

    private func transition(_ event: ConversationEvent) throws {
        state = try ConversationTransition.reduce(state: state, event: event)
    }

    private func fail(_ message: String) {
        capture.cancel()
        lastError = message
        if let next = try? ConversationTransition.reduce(
            state: state,
            event: .fail(message)
        ) {
            state = next
        }
    }
}
