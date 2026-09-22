import Combine
import Foundation

@MainActor
final class NovaConversationController: ObservableObject {
    @Published private(set) var state: NovaConversationState = .idle
    @Published private(set) var transcript: [NovaTranscriptEntry] = []
    @Published private(set) var currentUserTranscript = ""
    @Published private(set) var currentAssistantTranscript = ""
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var lastError: String?

    var voiceProcessingEnabled: Bool { audioIO.voiceProcessingEnabled }

    private let session: NovaSonicStreaming
    private let audioIO: NovaAudioIOProviding
    private let sessionTimeout: Duration
    private var eventTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var suppressAssistantAudio = false

    init(
        session: NovaSonicStreaming,
        audioIO: NovaAudioIOProviding,
        sessionTimeout: Duration = .seconds(450)
    ) {
        self.session = session
        self.audioIO = audioIO
        self.sessionTimeout = sessionTimeout
    }

    func start(voiceID: String) async throws {
        guard !state.isActive else { throw NovaSonicSessionError.alreadyActive }
        if case .failed = state { state = .idle }

        generation &+= 1
        let currentGeneration = generation
        transcript = []
        currentUserTranscript = ""
        currentAssistantTranscript = ""
        inputLevel = 0
        lastError = nil
        suppressAssistantAudio = false
        state = .connecting
        bindAudioCallbacks(generation: currentGeneration)

        do {
            let events = try await session.start(voiceID: voiceID)
            guard currentGeneration == generation else { return }
            try audioIO.start()
            state = .listening
            eventTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    for try await event in events {
                        guard !Task.isCancelled,
                              currentGeneration == self.generation else { return }
                        self.handle(event, generation: currentGeneration)
                    }
                    guard !Task.isCancelled,
                          currentGeneration == self.generation,
                          self.state.isActive else { return }
                    self.fail(
                        "Nova 2 Sonic closed the realtime session unexpectedly.",
                        generation: currentGeneration
                    )
                } catch {
                    guard !Task.isCancelled,
                          currentGeneration == self.generation else { return }
                    self.fail(error.localizedDescription, generation: currentGeneration)
                }
            }
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.sessionTimeout ?? .zero)
                guard let self, !Task.isCancelled,
                      currentGeneration == self.generation,
                      self.state.isActive else { return }
                self.fail(
                    "Nova 2 Sonic reached its bounded session limit. Start a new session to continue.",
                    generation: currentGeneration
                )
            }
        } catch {
            audioIO.stop()
            await session.stop()
            guard currentGeneration == generation else { return }
            state = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            throw error
        }
    }

    func end() async {
        guard state != .idle else { return }
        generation &+= 1
        state = .ending
        eventTask?.cancel()
        eventTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        audioIO.stop()
        await session.stop()
        inputLevel = 0
        suppressAssistantAudio = false
        currentUserTranscript = ""
        currentAssistantTranscript = ""
        state = .idle
    }

    func reset() async {
        await end()
        transcript = []
        currentUserTranscript = ""
        currentAssistantTranscript = ""
        lastError = nil
        state = .idle
    }

    func interruptPlayback() {
        guard state == .speaking || state == .responding else { return }
        audioIO.clearPlayback()
        currentAssistantTranscript = ""
        state = .listening
    }

    private func bindAudioCallbacks(generation: UInt64) {
        audioIO.onInputFrame = { [weak self] frame in
            guard let self, generation == self.generation else { return }
            let session = self.session
            Task {
                do {
                    try await session.sendAudio(frame)
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, generation == self.generation else { return }
                        self.fail(error.localizedDescription, generation: generation)
                    }
                }
            }
        }
        audioIO.onInputLevel = { [weak self] level in
            guard let self, generation == self.generation else { return }
            self.inputLevel = level
        }
        audioIO.onPlaybackStarted = { [weak self] in
            guard let self, generation == self.generation,
                  self.state != .userSpeaking else { return }
            self.state = .speaking
        }
        audioIO.onPlaybackDrained = { [weak self] in
            guard let self, generation == self.generation,
                  self.state == .speaking || self.state == .responding else { return }
            self.currentAssistantTranscript = ""
            self.state = .listening
        }
        audioIO.onError = { [weak self] message in
            guard let self, generation == self.generation else { return }
            self.fail(message, generation: generation)
        }
    }

    private func handle(_ event: NovaSonicOutputEvent, generation: UInt64) {
        guard generation == self.generation else { return }
        switch event {
        case .userSpeechStarted:
            suppressAssistantAudio = state == .speaking || state == .responding
            audioIO.clearPlayback()
            currentAssistantTranscript = ""
            state = .userSpeaking
        case .userSpeechEnded:
            if state == .userSpeaking || state == .listening {
                state = .responding
            }
        case .transcriptUpdated(let role, let text, _):
            switch role {
            case .user: currentUserTranscript = text
            case .assistant: currentAssistantTranscript = text
            }
        case .transcriptEnded(let role, let text, let stage, _):
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            switch role {
            case .user where stage == .final:
                currentUserTranscript = text
                commit(role: .user, text: text)
            case .assistant where stage == .final:
                currentAssistantTranscript = text
                commit(role: .assistant, text: text)
            case .assistant:
                currentAssistantTranscript = text
            case .user:
                currentUserTranscript = text
            }
        case .audio(let data):
            guard !suppressAssistantAudio else { return }
            do {
                try audioIO.enqueuePlayback(data)
                if state != .userSpeaking { state = .speaking }
            } catch {
                fail(error.localizedDescription, generation: generation)
            }
        case .audioEnded(let reason):
            let wasSuppressing = suppressAssistantAudio
            suppressAssistantAudio = false
            if reason == .interrupted || wasSuppressing {
                audioIO.clearPlayback()
                currentAssistantTranscript = ""
                state = .listening
            } else {
                audioIO.finishPlaybackTurn()
            }
        case .completionEnded:
            break
        }
    }

    private func commit(role: NovaTranscriptRole, text: String) {
        if let last = transcript.last, last.role == role, last.text == text { return }
        transcript.append(NovaTranscriptEntry(role: role, text: text))
    }

    private func fail(_ message: String, generation: UInt64) {
        guard generation == self.generation else { return }
        self.generation &+= 1
        eventTask?.cancel()
        eventTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        audioIO.clearPlayback()
        audioIO.stop()
        inputLevel = 0
        suppressAssistantAudio = false
        currentUserTranscript = ""
        currentAssistantTranscript = ""
        lastError = message
        state = .failed(message)
        let session = self.session
        Task { await session.stop() }
    }
}
