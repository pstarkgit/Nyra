import Foundation

struct SpeakableSentenceAccumulator: Equatable, Sendable {
    private var pending = ""

    var pendingText: String { pending }

    mutating func append(_ delta: String) -> [String] {
        guard !delta.isEmpty else { return [] }
        pending += delta
        var completed: [String] = []
        while let end = Self.firstSentenceEnd(in: pending) {
            let raw = String(pending[..<end])
            pending.removeSubrange(..<end)
            let sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                completed.append(sentence)
            }
        }
        return completed
    }

    mutating func flush() -> String? {
        defer { pending = "" }
        let fragment = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        return fragment.isEmpty ? nil : fragment
    }

    mutating func reset() {
        pending = ""
    }

    private static func firstSentenceEnd(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            guard isTerminal(text[index]) else {
                index = text.index(after: index)
                continue
            }

            var end = text.index(after: index)
            while end < text.endIndex, isTerminal(text[end]) {
                end = text.index(after: end)
            }
            while end < text.endIndex, isClosingDelimiter(text[end]) {
                end = text.index(after: end)
            }
            if end == text.endIndex || text[end].isWhitespace {
                return end
            }
            index = end
        }
        return nil
    }

    private static func isTerminal(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
    }

    private static func isClosingDelimiter(_ character: Character) -> Bool {
        "\"'’”)]}".contains(character)
    }
}

@MainActor
final class SerialSpeechQueue {
    var onChunkStarted: ((String) -> Void)?
    var onDrained: (() -> Void)?

    var isActive: Bool {
        worker != nil || !pending.isEmpty || synthesizer.isSpeaking
    }

    var isDrained: Bool { !isActive }

    private let synthesizer: SpeechSynthesizing
    private var pending: [String] = []
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(synthesizer: SpeechSynthesizing) {
        self.synthesizer = synthesizer
    }

    func enqueue(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pending.append(text)
        startWorkerIfNeeded()
    }

    func cancel() {
        let wasActive = isActive
        generation &+= 1
        pending.removeAll(keepingCapacity: true)
        worker?.cancel()
        worker = nil
        if wasActive {
            synthesizer.stop()
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        let currentGeneration = generation
        worker = Task { @MainActor [weak self] in
            await self?.drain(generation: currentGeneration)
        }
    }

    private func drain(generation: UInt64) async {
        while generation == self.generation, !Task.isCancelled {
            guard !pending.isEmpty else {
                worker = nil
                onDrained?()
                return
            }
            let text = pending.removeFirst()
            onChunkStarted?(text)
            await synthesizer.speak(text)
        }
    }
}
