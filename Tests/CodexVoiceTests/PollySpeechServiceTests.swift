import AVFoundation
import AWSPolly
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
    let voices = try await service.availableGenerativeVoices()
    let data = try await service.synthesize("Nyra Polly viability probe successful.")

    #expect(voices.contains(where: { $0.id == "Danielle" }))
    #expect(data.count > 1_000)
    _ = try AVAudioPlayer(data: data)
}

@MainActor
@Test func stopDuringSynthesisPreventsLatePlaybackAndFallback() async {
    let fallback = PollyFallbackSpy()
    let synthesizer = PollySpeechSynthesizer(
        synthesize: { _, _ in
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
        synthesize: { _, _ in throw PollyCanaryError.unavailable },
        fallback: fallback
    )

    await synthesizer.speak("Fallback response")

    #expect(fallback.spokenTexts == ["Fallback response"])
    guard case .localFallback = synthesizer.playbackState else {
        Issue.record("Expected a visible local fallback state")
        return
    }
}

@MainActor
@Test func appleModeRoutesDirectlyToOnDeviceSynthesizer() async {
    let recorder = PollyVoiceRecorder()
    let fallback = PollyFallbackSpy()
    let synthesizer = PollySpeechSynthesizer(
        synthesize: { _, voice in
            await recorder.record(voice)
            throw PollyCanaryError.unavailable
        },
        fallback: fallback,
        provider: .appleOnDevice
    )

    await synthesizer.speak("On-device response")
    let cloudVoiceIDs = await recorder.voiceIDs()

    #expect(fallback.spokenTexts == ["On-device response"])
    #expect(cloudVoiceIDs.isEmpty)
    #expect(synthesizer.playbackState == .ready)
}

@MainActor
@Test func selectedPollyVoiceIsUsedForSynthesis() async {
    let recorder = PollyVoiceRecorder()
    let fallback = PollyFallbackSpy()
    let ruth = PollyVoiceOption(
        id: PollyClientTypes.VoiceId.ruth.rawValue,
        name: "Ruth",
        languageCode: "en-US",
        gender: "Female"
    )
    let synthesizer = PollySpeechSynthesizer(
        synthesize: { _, voice in
            await recorder.record(voice)
            throw PollyCanaryError.unavailable
        },
        loadVoiceCatalog: { [.danielle, ruth] },
        fallback: fallback
    )

    await synthesizer.refreshPollyVoices()
    synthesizer.selectPollyVoice(ruth.id)
    await synthesizer.speak("Cloud response")
    let cloudVoiceIDs = await recorder.voiceIDs()

    #expect(cloudVoiceIDs == ["Ruth"])
    #expect(fallback.spokenTexts == ["Cloud response"])
}

@MainActor
@Test func providerAndPollyVoiceChoicesPersist() {
    let preferences = PollyMemoryPreferences()
    let local = SystemSpeechSynthesizer(
        driver: PollyFakeSpeechDriver(),
        selectedVoiceIdentifier: "test-voice"
    )
    let synthesizer = PollySpeechSynthesizer(
        fallback: local,
        preferences: preferences
    )

    synthesizer.selectProvider(.appleOnDevice)
    synthesizer.selectPollyVoice(PollyClientTypes.VoiceId.danielle.rawValue)

    #expect(preferences.values[AppPreferenceKey.speechOutputProvider]
        == SpeechOutputProvider.appleOnDevice.rawValue)
    #expect(preferences.values[AppPreferenceKey.selectedPollyVoiceID] == "Danielle")
}

private enum PollyCanaryError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Polly unavailable" }
}

private actor PollyVoiceRecorder {
    private var values: [String] = []

    func record(_ voice: PollyClientTypes.VoiceId) {
        values.append(voice.rawValue)
    }

    func voiceIDs() -> [String] { values }
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

@MainActor
private final class PollyFakeSpeechDriver: SpeechSynthesisDriving {
    weak var delegate: AVSpeechSynthesizerDelegate?
    func speak(_ utterance: AVSpeechUtterance) {}
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool { true }
}

private final class PollyMemoryPreferences: PreferenceStoring {
    var values: [String: String] = [:]
    func string(forKey defaultName: String) -> String? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value as? String
    }
}
