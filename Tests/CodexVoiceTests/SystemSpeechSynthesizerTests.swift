import AVFoundation
import Testing
@testable import CodexVoice

@MainActor
@Test func speaksSelectedVoiceAndCompletesOnDelegateFinish() async {
    let driver = FakeSpeechDriver()
    let synthesizer = SystemSpeechSynthesizer(driver: driver)

    let task = Task { await synthesizer.speak("Build complete") }
    await Task.yield()
    #expect(driver.lastUtterance?.speechString == "Build complete")
    driver.finish()
    await task.value

    #expect(synthesizer.isSpeaking == false)
}

@MainActor
@Test func stopCancelsPendingSpeechExactlyOnce() async {
    let driver = FakeSpeechDriver()
    let synthesizer = SystemSpeechSynthesizer(driver: driver)
    let task = Task { await synthesizer.speak("Long response") }
    await Task.yield()

    synthesizer.stop()
    await task.value

    #expect(driver.stopCalls == 1)
    #expect(synthesizer.isSpeaking == false)
}

@Test func speechReadinessRequiresBothPermissionsAndOnDeviceSupport() {
    #expect(AppleSpeechSession.readiness(
        speechPermission: .denied,
        microphonePermission: .authorized,
        supportsOnDevice: true
    ) == .speechPermissionDenied)
    #expect(AppleSpeechSession.readiness(
        speechPermission: .authorized,
        microphonePermission: .denied,
        supportsOnDevice: true
    ) == .microphonePermissionDenied)
    #expect(AppleSpeechSession.readiness(
        speechPermission: .authorized,
        microphonePermission: .authorized,
        supportsOnDevice: false
    ) == .onDeviceRecognitionUnavailable)
    #expect(AppleSpeechSession.readiness(
        speechPermission: .authorized,
        microphonePermission: .authorized,
        supportsOnDevice: true
    ) == .ready)
}

@MainActor
private final class FakeSpeechDriver: SpeechSynthesisDriving {
    weak var delegate: AVSpeechSynthesizerDelegate?
    private let callbackSynthesizer = AVSpeechSynthesizer()
    var lastUtterance: AVSpeechUtterance?
    var stopCalls = 0

    func speak(_ utterance: AVSpeechUtterance) {
        lastUtterance = utterance
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopCalls += 1
        guard let lastUtterance else { return false }
        delegate?.speechSynthesizer?(callbackSynthesizer, didCancel: lastUtterance)
        return true
    }

    func finish() {
        guard let lastUtterance else { return }
        delegate?.speechSynthesizer?(callbackSynthesizer, didFinish: lastUtterance)
    }
}
