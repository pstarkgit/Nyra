import AVFoundation
import Foundation

struct SpeechVoiceOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let language: String
    let isPremium: Bool

    var label: String { isPremium ? "\(name) — Premium" : name }
}

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
    private var speechProcess: Process?
    let availableVoices: [SpeechVoiceOption]
    var selectedVoiceIdentifier: String?
    private(set) var isSpeaking = false

    init(
        driver: SpeechSynthesisDriving = AVSpeechSynthesizer(),
        selectedVoiceIdentifier: String? = nil
    ) {
        self.driver = driver
        let desktopVoices = driver is AVSpeechSynthesizer
            ? Self.loadDesktopVoices()
            : []
        self.availableVoices = desktopVoices
        self.selectedVoiceIdentifier = selectedVoiceIdentifier
            ?? Self.preferredVoiceIdentifier(in: desktopVoices)
        super.init()
        driver.delegate = self
    }

    func speak(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isSpeaking { stop() }

        if let selectedVoiceIdentifier,
           selectedVoiceIdentifier.hasPrefix("say:") {
            let voiceName = String(selectedVoiceIdentifier.dropFirst(4))
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/say")
            process.arguments = ["-v", voiceName, "-r", "175", text]
            process.terminationHandler = { [weak self, weak process] _ in
                Task { @MainActor [weak self, weak process] in
                    guard self?.speechProcess === process else { return }
                    self?.finishPlayback()
                }
            }
            do {
                try process.run()
                speechProcess = process
                isSpeaking = true
                await withCheckedContinuation { completion = $0 }
                return
            } catch {
                speechProcess = nil
            }
        }

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
        if let speechProcess {
            if speechProcess.isRunning { speechProcess.terminate() }
            finishPlayback()
            return
        }
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
        speechProcess = nil
        let completion = completion
        self.completion = nil
        completion?.resume()
    }

    nonisolated static func parseSayVoiceList(_ output: String) -> [SpeechVoiceOption] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine)
            guard let hash = line.firstIndex(of: "#") else { return nil }
            let head = line[..<hash]
            let tokens = head.split(whereSeparator: \Character.isWhitespace)
            guard let localeIndex = tokens.firstIndex(where: {
                $0.count == 5 && $0[$0.index($0.startIndex, offsetBy: 2)] == "_"
            }) else { return nil }
            let locale = String(tokens[localeIndex])
            guard locale.hasPrefix("en_") else { return nil }
            let name = tokens[..<localeIndex].joined(separator: " ")
            guard !name.isEmpty else { return nil }
            let premium = name.localizedCaseInsensitiveContains("premium")
            return SpeechVoiceOption(
                id: "say:\(name)",
                name: name,
                language: locale,
                isPremium: premium
            )
        }.sorted {
            if $0.isPremium != $1.isPremium { return $0.isPremium && !$1.isPremium }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    nonisolated static func preferredVoiceIdentifier(
        in voices: [SpeechVoiceOption]
    ) -> String? {
        voices.first(where: \.isPremium)?.id ?? voices.first?.id
    }

    private static func loadDesktopVoices() -> [SpeechVoiceOption] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return parseSayVoiceList(String(decoding: data, as: UTF8.self))
        } catch {
            return []
        }
    }
}
