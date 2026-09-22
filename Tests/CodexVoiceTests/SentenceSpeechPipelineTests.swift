import Foundation
import Testing
@testable import CodexVoice

@Test func sentenceAccumulatorHandlesBoundariesAcrossDeltasAndFlushesTail() {
    var accumulator = SpeakableSentenceAccumulator()

    #expect(accumulator.append("First sen").isEmpty)
    #expect(accumulator.append("tence. Second") == ["First sentence."])
    #expect(accumulator.append(" sentence! Final fragment") == ["Second sentence!"])
    #expect(accumulator.flush() == "Final fragment")
    #expect(accumulator.pendingText.isEmpty)
}

@Test func sentenceAccumulatorDoesNotEmitTextTwice() {
    var accumulator = SpeakableSentenceAccumulator()

    #expect(accumulator.append("One.") == ["One."])
    #expect(accumulator.append(" Two?") == ["Two?"])
    #expect(accumulator.append("").isEmpty)
    #expect(accumulator.flush() == nil)
}

@Test func sentenceAccumulatorKeepsDecimalUntilRealBoundary() {
    var accumulator = SpeakableSentenceAccumulator()

    #expect(accumulator.append("Version 0.5 ships now.") == ["Version 0.5 ships now."])
    #expect(accumulator.flush() == nil)
}

@MainActor
@Test func serialSpeechQueuePlaysInOrderWithoutBlockingEnqueue() async throws {
    let synthesizer = QueueSpeechSynthesizer()
    let queue = SerialSpeechQueue(synthesizer: synthesizer)
    var drained = 0
    queue.onDrained = { drained += 1 }

    queue.enqueue("First sentence.")
    queue.enqueue("Second sentence.")
    try await waitForQueue { synthesizer.spoken == ["First sentence."] }

    synthesizer.finish()
    try await waitForQueue {
        synthesizer.spoken == ["First sentence.", "Second sentence."]
    }
    #expect(drained == 0)

    synthesizer.finish()
    try await waitForQueue { queue.isDrained }
    #expect(drained == 1)
}

@MainActor
@Test func serialSpeechQueueCancelsActiveAndQueuedSpeech() async throws {
    let synthesizer = QueueSpeechSynthesizer()
    let queue = SerialSpeechQueue(synthesizer: synthesizer)
    var drained = 0
    queue.onDrained = { drained += 1 }

    queue.enqueue("First sentence.")
    queue.enqueue("Never speak this.")
    try await waitForQueue { synthesizer.spoken == ["First sentence."] }

    queue.cancel()
    await Task.yield()

    #expect(synthesizer.stopCalls == 1)
    #expect(synthesizer.spoken == ["First sentence."])
    #expect(queue.isDrained)
    #expect(drained == 0)
}

@MainActor
private final class QueueSpeechSynthesizer: SpeechSynthesizing {
    private(set) var isSpeaking = false
    private(set) var spoken: [String] = []
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

@MainActor
private func waitForQueue(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock.now >= deadline {
            throw SentenceSpeechPipelineTestError.timeout
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private enum SentenceSpeechPipelineTestError: Error {
    case timeout
}
