import Foundation
import Testing
@testable import CodexVoice

@Test func trailingSilenceFinalizesOnlyAfterRealSpeech() {
    var detector = VoiceActivityDetector(
        speechThreshold: 0.03,
        minimumSpeech: 0.20,
        trailingSilence: 0.70
    )

    #expect(detector.consume(rms: 0.001, frameDuration: 1.0) == nil)
    #expect(detector.consume(rms: 0.10, frameDuration: 0.10) == nil)
    #expect(detector.consume(rms: 0.10, frameDuration: 0.10) == .speechStarted)
    #expect(detector.consume(rms: 0.001, frameDuration: 0.69) == nil)
    #expect(detector.consume(rms: 0.001, frameDuration: 0.01) == .utteranceEnded)
}

@Test func shortNoiseNeverStartsAnUtterance() {
    var detector = VoiceActivityDetector(
        speechThreshold: 0.03,
        minimumSpeech: 0.20,
        trailingSilence: 0.70
    )

    #expect(detector.consume(rms: 0.20, frameDuration: 0.05) == nil)
    #expect(detector.consume(rms: 0.001, frameDuration: 1.0) == nil)
    #expect(detector.hasDetectedSpeech == false)
}

@Test func defaultDetectorRecognizesMeasuredSoftSpeechAndTrailingSilence() {
    var detector = VoiceActivityDetector()

    #expect(detector.consume(rms: 0.008, frameDuration: 0.10) == nil)
    #expect(detector.consume(rms: 0.008, frameDuration: 0.10) == .speechStarted)
    #expect(detector.consume(rms: 0.001, frameDuration: 0.59) == nil)
    #expect(detector.consume(rms: 0.001, frameDuration: 0.01) == .utteranceEnded)
}

@Test func resetAllowsAnotherUtterance() {
    var detector = VoiceActivityDetector(
        speechThreshold: 0.03,
        minimumSpeech: 0.10,
        trailingSilence: 0.20
    )
    #expect(detector.consume(rms: 0.1, frameDuration: 0.1) == .speechStarted)
    #expect(detector.consume(rms: 0.0, frameDuration: 0.2) == .utteranceEnded)
    detector.reset()
    #expect(detector.consume(rms: 0.1, frameDuration: 0.1) == .speechStarted)
}

@Test func computesRMSForFloatSamples() {
    #expect(AudioLevel.rms(samples: [0.0, 0.5, -0.5, 0.0]) == 0.35355338)
    #expect(AudioLevel.rms(samples: []) == 0)
}
