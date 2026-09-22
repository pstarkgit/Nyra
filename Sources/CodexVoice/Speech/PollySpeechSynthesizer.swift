@preconcurrency import AVFoundation
import AWSPolly
import Combine
import Foundation

enum SpeechOutputProvider: String, CaseIterable, Identifiable, Sendable {
    case appleOnDevice = "apple-on-device"
    case amazonPolly = "amazon-polly"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleOnDevice: return "Apple On-Device"
        case .amazonPolly: return "AWS Polly"
        }
    }
}

enum PollyPlaybackState: Equatable {
    case ready
    case synthesizing
    case speaking
    case localFallback(String)
}

@MainActor
final class PollySpeechSynthesizer: NSObject, ObservableObject, SpeechSynthesizing,
    AVAudioPlayerDelegate {
    typealias SynthesisOperation = @Sendable (
        String,
        PollyClientTypes.VoiceId
    ) async throws -> Data
    typealias VoiceCatalogOperation = @Sendable () async throws -> [PollyVoiceOption]

    @Published private(set) var playbackState: PollyPlaybackState = .ready
    @Published private(set) var provider: SpeechOutputProvider
    @Published private(set) var selectedPollyVoiceID: String
    @Published private(set) var pollyVoices: [PollyVoiceOption] = [.danielle]
    @Published private(set) var isRefreshingPollyVoices = false
    @Published private(set) var voiceCatalogError: String?

    let appleVoices: [SpeechVoiceOption]

    private let baseConfiguration: PollySpeechConfiguration
    private let synthesize: SynthesisOperation
    private let loadVoiceCatalog: VoiceCatalogOperation
    private let fallback: SpeechSynthesizing
    private let systemFallback: SystemSpeechSynthesizer?
    private let preferences: PreferenceStoring?
    private var player: AVAudioPlayer?
    private var completion: CheckedContinuation<Void, Never>?
    private var generation: UInt64 = 0

    var selectedAppleVoiceIdentifier: String {
        systemFallback?.selectedVoiceIdentifier ?? ""
    }

    var statusLabel: String {
        switch playbackState {
        case .synthesizing:
            return "AWS Polly · Synthesizing…"
        case .speaking:
            return provider == .appleOnDevice
                ? "Apple On-Device · Speaking"
                : "AWS Polly · Speaking"
        case .localFallback:
            return "Polly unavailable · Apple fallback"
        case .ready:
            switch provider {
            case .appleOnDevice:
                let selected = appleVoices.first {
                    $0.id == selectedAppleVoiceIdentifier
                }?.name ?? "System Voice"
                return "Apple On-Device · \(selected)"
            case .amazonPolly:
                let selected = pollyVoices.first {
                    $0.id == selectedPollyVoiceID
                }?.name ?? selectedPollyVoiceID
                return "AWS Polly Generative · \(selected)"
            }
        }
    }

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
        fallback: SystemSpeechSynthesizer,
        preferences: PreferenceStoring = UserDefaults.standard
    ) {
        baseConfiguration = configuration
        synthesize = { text, voice in
            var selectedConfiguration = configuration
            selectedConfiguration.voice = voice
            let service = try PollySpeechService(configuration: selectedConfiguration)
            return try await service.synthesize(text)
        }
        loadVoiceCatalog = {
            let service = try PollySpeechService(configuration: configuration)
            return try await service.availableGenerativeVoices()
        }
        self.fallback = fallback
        systemFallback = fallback
        self.preferences = preferences
        appleVoices = fallback.availableVoices
        provider = SpeechOutputProvider(rawValue: preferences.string(
            forKey: AppPreferenceKey.speechOutputProvider
        ) ?? "") ?? .amazonPolly
        selectedPollyVoiceID = preferences.string(
            forKey: AppPreferenceKey.selectedPollyVoiceID
        ) ?? PollyClientTypes.VoiceId.danielle.rawValue
    }

    init(
        synthesize: @escaping SynthesisOperation,
        loadVoiceCatalog: @escaping VoiceCatalogOperation = { [.danielle] },
        fallback: SpeechSynthesizing,
        provider: SpeechOutputProvider = .amazonPolly,
        selectedPollyVoiceID: String = PollyClientTypes.VoiceId.danielle.rawValue
    ) {
        baseConfiguration = PollySpeechConfiguration()
        self.synthesize = synthesize
        self.loadVoiceCatalog = loadVoiceCatalog
        self.fallback = fallback
        systemFallback = nil
        preferences = nil
        appleVoices = []
        self.provider = provider
        self.selectedPollyVoiceID = selectedPollyVoiceID
    }

    func selectProvider(_ provider: SpeechOutputProvider) {
        if isSpeaking { stop() }
        self.provider = provider
        preferences?.set(provider.rawValue, forKey: AppPreferenceKey.speechOutputProvider)
        playbackState = .ready
    }

    func selectPollyVoice(_ id: String) {
        guard pollyVoices.contains(where: { $0.id == id }) else { return }
        if isSpeaking { stop() }
        selectedPollyVoiceID = id
        preferences?.set(id, forKey: AppPreferenceKey.selectedPollyVoiceID)
        playbackState = .ready
    }

    func selectAppleVoice(_ id: String) {
        guard appleVoices.contains(where: { $0.id == id }),
              let systemFallback else { return }
        if isSpeaking { stop() }
        objectWillChange.send()
        systemFallback.selectedVoiceIdentifier = id
        preferences?.set(id, forKey: AppPreferenceKey.selectedVoiceIdentifier)
        playbackState = .ready
    }

    func refreshPollyVoices() async {
        guard !isRefreshingPollyVoices else { return }
        isRefreshingPollyVoices = true
        voiceCatalogError = nil
        defer { isRefreshingPollyVoices = false }

        do {
            let loaded = try await loadVoiceCatalog()
            guard !loaded.isEmpty else { throw PollySpeechServiceError.emptyVoiceCatalog }
            pollyVoices = loaded
            if !loaded.contains(where: { $0.id == selectedPollyVoiceID }) {
                let replacement = loaded.first(where: {
                    $0.id == PollyClientTypes.VoiceId.danielle.rawValue
                }) ?? loaded[0]
                selectPollyVoice(replacement.id)
            }
        } catch {
            voiceCatalogError = error.localizedDescription
        }
    }

    func speak(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isSpeaking { stop() }

        generation &+= 1
        let currentGeneration = generation

        if provider == .appleOnDevice {
            playbackState = .speaking
            await fallback.speak(text)
            guard currentGeneration == generation else { return }
            playbackState = .ready
            return
        }

        playbackState = .synthesizing
        do {
            let voice = PollyClientTypes.VoiceId(rawValue: selectedPollyVoiceID)
                ?? baseConfiguration.voice
            let data = try await synthesize(text, voice)
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
