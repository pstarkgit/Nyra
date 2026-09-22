import AVFoundation
import Foundation
import Testing
@testable import CodexVoice

@Test func pollyDefaultsUseLeastPrivilegeProfileAndExpectedRegion() {
    let configuration = PollySpeechConfiguration()

    #expect(configuration.profile == "nyra-polly")
    #expect(configuration.region == "us-west-2")
    #expect(PollySpeechConfiguration.defaultVoiceName == "Danielle")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NYRA_RUN_LIVE_POLLY_TEST"] == "1"))
func livePollyGenerativeCanaryReturnsPlayableAudio() async throws {
    let configuration = PollySpeechConfiguration()
    let service = try PollySpeechService(configuration: configuration)
    let data = try await service.synthesize("Nyra Polly viability probe successful.")

    #expect(data.count > 1_000)
    _ = try AVAudioPlayer(data: data)
}

@MainActor
@Test func stopDuringSynthesisPreventsLatePlaybackAndFallback() async {
    let fallback = PollyFallbackSpy()
    let synthesizer = PollySpeechSynthesizer(
        synthesize: { _ in
            try await Task.sleep(for: .milliseconds(100))
            return Data([0x01])
        },
        fallback: fallback
    )

    let task = Task { await synthesizer.speak("Do not play this late response") }
    await Task.yield()
    #expect(synthesizer.playbackState == .synthesizing)

    synthesizer.stop()
    await task.value

    #expect(synthesizer.playbackState == .ready)
    #expect(synthesizer.isSpeaking == false)
    #expect(fallback.spokenTexts.isEmpty)
}

@MainActor
@Test func pollyFailureUsesAudibleLocalFallback() async {
    let fallback = PollyFallbackSpy()
    let synthesizer = PollySpeechSynthesizer(
        synthesize: { _ in throw PollyCanaryError.unavailable },
        fallback: fallback
    )

    await synthesizer.speak("Fallback response")

    #expect(fallback.spokenTexts == ["Fallback response"])
    guard case .localFallback = synthesizer.playbackState else {
        Issue.record("Expected a visible local fallback state")
        return
    }
}

private enum PollyCanaryError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Polly unavailable" }
}

@MainActor
private final class PollyFallbackSpy: SpeechSynthesizing {
    var isSpeaking = false
    var spokenTexts: [String] = []

    func speak(_ text: String) async {
        spokenTexts.append(text)
    }

    func stop() {
        isSpeaking = false
    }
}
