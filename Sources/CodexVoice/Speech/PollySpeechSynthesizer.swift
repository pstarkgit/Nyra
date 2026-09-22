@preconcurrency import AVFoundation
import Combine
import Foundation

enum PollyPlaybackState: Equatable {
    case ready
    case synthesizing
    case speaking
    case localFallback(String)

    var label: String {
        switch self {
        case .ready:
            return "AWS Polly Generative · Danielle"
        case .synthesizing:
            return "AWS Polly Generative · Synthesizing…"
        case .speaking:
            return "AWS Polly Generative · Speaking"
        case .localFallback:
            return "Polly unavailable · Apple voice fallback"
        }
    }
}

@MainActor
final class PollySpeechSynthesizer: NSObject, ObservableObject, SpeechSynthesizing,
    AVAudioPlayerDelegate {
    typealias SynthesisOperation = @Sendable (String) async throws -> Data

    @Published private(set) var playbackState: PollyPlaybackState = .ready

    private let synthesize: SynthesisOperation
    private let fallback: SpeechSynthesizing
    private var player: AVAudioPlayer?
    private var completion: CheckedContinuation<Void, Never>?
    private var generation: UInt64 = 0

    var isSpeaking: Bool {
        switch playbackState {
        case .synthesizing, .speaking:
            return true
        case .ready, .localFallback:
            return fallback.isSpeaking
        }
    }

    init(
        configuration: PollySpeechConfiguration = PollySpeechConfiguration(),
        fallback: SpeechSynthesizing
    ) {
        synthesize = { text in
            let service = try PollySpeechService(configuration: configuration)
            return try await service.synthesize(text)
        }
        self.fallback = fallback
    }

    init(
        synthesize: @escaping SynthesisOperation,
        fallback: SpeechSynthesizing
    ) {
        self.synthesize = synthesize
        self.fallback = fallback
    }

    func speak(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isSpeaking { stop() }

        generation &+= 1
        let currentGeneration = generation
        playbackState = .synthesizing
        do {
            let data = try await synthesize(text)
            guard currentGeneration == generation else { return }
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            playbackState = .speaking
            await withCheckedContinuation { continuation in
                completion = continuation
                if !player.play() { finishPlayback() }
            }
            guard currentGeneration == generation else { return }
            playbackState = .ready
        } catch {
            guard currentGeneration == generation else { return }
            playbackState = .localFallback(error.localizedDescription)
            await fallback.speak(text)
        }
    }

    func stop() {
        generation &+= 1
        player?.stop()
        fallback.stop()
        finishPlayback()
        playbackState = .ready
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in self?.finishPlayback() }
    }

    private func finishPlayback() {
        player = nil
        let completion = completion
        self.completion = nil
        completion?.resume()
    }
}
