import AVFoundation
import Foundation

@MainActor
protocol SpeechSynthesisDriving: AnyObject {
    var delegate: AVSpeechSynthesizerDelegate? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesisDriving {}

@MainActor
protocol SpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String) async
    func stop()
}

@MainActor
final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing,
    AVSpeechSynthesizerDelegate {
    private let driver: SpeechSynthesisDriving
    private var completion: CheckedContinuation<Void, Never>?
    var selectedVoiceIdentifier: String?
    private(set) var isSpeaking = false

    init(
        driver: SpeechSynthesisDriving = AVSpeechSynthesizer(),
        selectedVoiceIdentifier: String? = nil
    ) {
        self.driver = driver
        self.selectedVoiceIdentifier = selectedVoiceIdentifier
        super.init()
        driver.delegate = self
    }

    func speak(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isSpeaking { stop() }

        let utterance = AVSpeechUtterance(string: text)
        if let selectedVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        isSpeaking = true
        await withCheckedContinuation { continuation in
            completion = continuation
            driver.speak(utterance)
        }
    }

    func stop() {
        guard isSpeaking else { return }
        if !driver.stopSpeaking(at: .immediate) {
            finishPlayback()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.finishPlayback() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.finishPlayback() }
    }

    private func finishPlayback() {
        guard isSpeaking || completion != nil else { return }
        isSpeaking = false
        let completion = completion
        self.completion = nil
        completion?.resume()
    }
}
