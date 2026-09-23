import Foundation
import Testing
@testable import CodexVoice

@MainActor
@Test func novaControllerStreamsFramesAndReturnsToListeningAfterPlayback() async throws {
    let session = FakeNovaSession()
    let audio = FakeNovaAudioIO()
    let controller = NovaConversationController(session: session, audioIO: audio)
    try await controller.start(voiceID: "tiffany")
    #expect(controller.state == .listening)
    #expect(controller.voiceProcessingEnabled)

    let inputFrame = Data(repeating: 3, count: 1_024)
    audio.emitInput(inputFrame)
    try await waitUntil { await session.audioFrames() == [inputFrame] }

    await session.emit(.userSpeechStarted)
    await session.emit(.transcriptEnded(
        role: .user,
        text: "Hello Nyra",
        stage: .final,
        stopReason: .partialTurn
    ))
    await session.emit(.userSpeechEnded)
    await session.emit(.transcriptUpdated(
        role: .assistant,
        text: "Hello Patrick",
        stage: .speculative
    ))
    await session.emit(.audio(Data([1, 2, 3, 4])))
    await session.emit(.audioEnded(.endTurn))
    try await waitUntil { audio.finishCount == 1 }
    audio.drainPlayback()
    await session.emit(.transcriptEnded(
        role: .assistant,
        text: "Hello Patrick",
        stage: .final,
        stopReason: .endTurn
    ))

    try await waitUntil { controller.transcript.count == 2 }
    #expect(controller.transcript.map(\.role) == [.user, .assistant])
    #expect(controller.transcript.map(\.text) == ["Hello Nyra", "Hello Patrick"])
    #expect(controller.state == .listening)
    #expect(audio.enqueued == [Data([1, 2, 3, 4])])
    #expect(audio.finishCount == 1)
}

@MainActor
@Test func novaControllerClearsQueuedAndInflightPlaybackOnBargeIn() async throws {
    let session = FakeNovaSession()
    let audio = FakeNovaAudioIO()
    let controller = NovaConversationController(session: session, audioIO: audio)
    try await controller.start(voiceID: "tiffany")
    await session.emit(.audio(Data(repeating: 8, count: 64)))
    try await waitUntil { controller.state == .speaking }
    let clearsBeforeBargeIn = audio.clearCount

    await session.emit(.userSpeechStarted)
    try await waitUntil { controller.state == .userSpeaking }
    #expect(audio.clearCount == clearsBeforeBargeIn + 1)
    let queuedAtInterruption = audio.enqueued
    await session.emit(.audio(Data(repeating: 9, count: 64)))
    try await Task.sleep(for: .milliseconds(20))
    #expect(audio.enqueued == queuedAtInterruption)

    await session.emit(.audioEnded(.interrupted))
    try await waitUntil { controller.state == .listening }
    #expect(audio.clearCount == clearsBeforeBargeIn + 2)
}

@MainActor
@Test func novaControllerIgnoresEventsFromPriorGeneration() async throws {
    let session = FakeNovaSession()
    let audio = FakeNovaAudioIO()
    let controller = NovaConversationController(session: session, audioIO: audio)
    try await controller.start(voiceID: "tiffany")
    await controller.end()
    try await controller.start(voiceID: "tiffany")
    #expect(controller.state == .listening)

    await session.emit(.userSpeechStarted, streamIndex: 0)
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.state == .listening)
}

@MainActor
@Test func novaControllerSurfacesSessionFailureAndResetsCleanly() async throws {
    let session = FakeNovaSession()
    let audio = FakeNovaAudioIO()
    let controller = NovaConversationController(session: session, audioIO: audio)
    try await controller.start(voiceID: "tiffany")
    await session.fail(FakeNovaError.disconnected)
    try await waitUntil {
        if case .failed = controller.state { return true }
        return false
    }
    #expect(controller.lastError == "Nova test disconnected")
    #expect(audio.stopCount == 1)

    await controller.reset()
    #expect(controller.state == .idle)
    #expect(controller.lastError == nil)
    #expect(controller.transcript.isEmpty)
}

@MainActor
@Test func novaControllerTimesOutAndStopsPersistentSession() async throws {
    let session = FakeNovaSession()
    let audio = FakeNovaAudioIO()
    let controller = NovaConversationController(
        session: session,
        audioIO: audio,
        sessionTimeout: .milliseconds(20)
    )
    try await controller.start(voiceID: "tiffany")
    try await waitUntil(timeout: .seconds(1)) {
        if case .failed = controller.state { return true }
        return false
    }
    #expect(controller.lastError?.contains("bounded session limit") == true)
    try await waitUntil { await session.stopCount() >= 1 }
    #expect(audio.stopCount == 1)
}

@MainActor
@Test func novaControllerListensBeforeResponseHeadersAndSendsEarlyFrames() async throws {
    let probe = NovaConnectionProbe(mode: .consumeInput)
    let session = NovaSonicSession {
        input, configuration, output, startInput in
        try await probe.run(
            input: input,
            configuration: configuration,
            output: output,
            startInput: startInput
        )
    }
    let audio = FakeNovaAudioIO()
    let controller = NovaConversationController(session: session, audioIO: audio)

    try await controller.start(voiceID: "tiffany")
    #expect(controller.state == .listening)
    try await waitUntil { await probe.hasStarted() }

    audio.emitInput(Data(repeating: 7, count: 1_024))
    try await waitUntil { await probe.inputEventCount() >= 7 }
    #expect(await probe.inputEventCount() >= 7)

    await controller.end()
    try await waitUntil { await probe.hasExited() }
}

@MainActor
@Test func novaControllerSurfacesAsynchronousConnectionFailure() async throws {
    let probe = NovaConnectionProbe(mode: .deferredFailure)
    let session = NovaSonicSession {
        input, configuration, output, startInput in
        try await probe.run(
            input: input,
            configuration: configuration,
            output: output,
            startInput: startInput
        )
    }
    let audio = FakeNovaAudioIO()
    let controller = NovaConversationController(session: session, audioIO: audio)

    try await controller.start(voiceID: "tiffany")
    #expect(controller.state == .listening)
    try await waitUntil { await probe.hasStarted() }
    await probe.requestFailure()

    try await waitUntil {
        if case .failed = controller.state { return true }
        return false
    }
    #expect(controller.lastError == "Nova test disconnected")
    try await waitUntil { await probe.hasExited() }
}

@Test func novaSessionCancellationClosesInputAndOutputCleanly() async throws {
    let probe = NovaConnectionProbe(mode: .consumeInput)
    let session = NovaSonicSession {
        input, configuration, output, startInput in
        try await probe.run(
            input: input,
            configuration: configuration,
            output: output,
            startInput: startInput
        )
    }
    let events = try await session.start(voiceID: "tiffany")
    let outputClosed = Task {
        do {
            for try await _ in events {}
            return true
        } catch {
            return false
        }
    }
    try await waitUntilOffMain { await probe.hasStarted() }

    await session.stop()

    #expect(await outputClosed.value)
    try await waitUntilOffMain { await probe.hasExited() }
    do {
        try await session.sendAudio(Data([1, 2]))
        Issue.record("Audio send unexpectedly succeeded after session cancellation")
    } catch let error as NovaSonicSessionError {
        #expect(error == .inactive)
    }
}

private actor NovaConnectionProbe {
    enum Mode: Sendable {
        case consumeInput
        case deferredFailure
    }

    private let mode: Mode
    private var started = false
    private var exited = false
    private var eventCount = 0
    private var failureRequested = false

    init(mode: Mode) {
        self.mode = mode
    }

    func run(
        input: NovaSonicInputStream,
        configuration: NovaSonicConfiguration,
        output: NovaSonicOutputContinuation,
        startInput: NovaSonicInputStarter
    ) async throws {
        _ = configuration
        _ = output
        started = true
        defer { exited = true }
        await startInput.start()

        switch mode {
        case .consumeInput:
            for try await _ in input {
                eventCount += 1
            }
        case .deferredFailure:
            while !failureRequested {
                try await Task.sleep(for: .milliseconds(5))
            }
            throw FakeNovaError.disconnected
        }
    }

    func requestFailure() {
        failureRequested = true
    }

    func hasStarted() -> Bool { started }
    func hasExited() -> Bool { exited }
    func inputEventCount() -> Int { eventCount }
}

@MainActor
@Test func novaControllerEndIsBoundedWhenConnectionIgnoresCancellation() async throws {
    let probe = CancellationResistantNovaProbe()
    let session = NovaSonicSession {
        input, configuration, output, startInput in
        try await probe.run(
            input: input,
            configuration: configuration,
            output: output,
            startInput: startInput
        )
    }
    let controller = NovaConversationController(
        session: session,
        audioIO: FakeNovaAudioIO()
    )

    try await controller.start(voiceID: "tiffany")
    try await waitUntil { await probe.isSuspended() }
    let clock = ContinuousClock()
    let start = clock.now

    await controller.end()

    #expect(start.duration(to: clock.now) < .seconds(1))
    #expect(controller.state == .idle)
    #expect(!(await probe.hasExited()))

    await probe.emitLateEvent()
    try await Task.sleep(for: .milliseconds(20))
    #expect(controller.state == .idle)

    await probe.release()
    try await waitUntil { await probe.hasExited() }
}

private actor CancellationResistantNovaProbe {
    private var suspended = false
    private var exited = false
    private var output: NovaSonicOutputContinuation?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run(
        input: NovaSonicInputStream,
        configuration: NovaSonicConfiguration,
        output: NovaSonicOutputContinuation,
        startInput: NovaSonicInputStarter
    ) async throws {
        _ = input
        _ = configuration
        self.output = output
        defer {
            self.output = nil
            exited = true
        }
        await startInput.start()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            suspended = true
        }
    }

    func emitLateEvent() {
        output?.yield(.userSpeechStarted)
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func isSuspended() -> Bool { suspended }
    func hasExited() -> Bool { exited }
}

private func waitUntilOffMain(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        if clock.now >= deadline { throw FakeNovaError.disconnected }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private enum FakeNovaError: LocalizedError {
    case disconnected
    var errorDescription: String? { "Nova test disconnected" }
}

private actor FakeNovaSession: NovaSonicStreaming {
    private var continuations: [
        AsyncThrowingStream<NovaSonicOutputEvent, Error>.Continuation
    ] = []
    private var receivedAudio: [Data] = []
    private var stops = 0

    func start(
        voiceID: String
    ) async throws -> AsyncThrowingStream<NovaSonicOutputEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<
            NovaSonicOutputEvent,
            Error
        >.makeStream()
        continuations.append(continuation)
        return stream
    }

    func sendAudio(_ data: Data) async throws {
        receivedAudio.append(data)
    }

    func stop() async {
        stops += 1
    }

    func emit(_ event: NovaSonicOutputEvent, streamIndex: Int? = nil) {
        guard !continuations.isEmpty else { return }
        continuations[streamIndex ?? continuations.count - 1].yield(event)
    }

    func fail(_ error: Error) {
        continuations.last?.finish(throwing: error)
    }

    func audioFrames() -> [Data] { receivedAudio }
    func stopCount() -> Int { stops }
}

@MainActor
private final class FakeNovaAudioIO: NovaAudioIOProviding {
    var onInputFrame: ((Data) -> Void)?
    var onInputLevel: ((Float) -> Void)?
    var onPlaybackStarted: (() -> Void)?
    var onPlaybackDrained: (() -> Void)?
    var onError: ((String) -> Void)?
    private(set) var voiceProcessingEnabled = false
    private(set) var enqueued: [Data] = []
    private(set) var clearCount = 0
    private(set) var finishCount = 0
    private(set) var stopCount = 0

    func start() throws {
        voiceProcessingEnabled = true
    }

    func enqueuePlayback(_ data: Data) throws {
        enqueued.append(data)
        onPlaybackStarted?()
    }

    func finishPlaybackTurn() {
        finishCount += 1
    }

    func clearPlayback() {
        clearCount += 1
    }

    func stop() {
        stopCount += 1
        voiceProcessingEnabled = false
    }

    func emitInput(_ data: Data) {
        onInputFrame?(data)
    }

    func drainPlayback() {
        onPlaybackDrained?()
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        if clock.now >= deadline { throw FakeNovaError.disconnected }
        try await Task.sleep(for: .milliseconds(5))
    }
}
