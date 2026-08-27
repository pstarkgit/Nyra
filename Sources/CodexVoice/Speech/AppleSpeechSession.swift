@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

enum SpeechPermissionState: Equatable, Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

enum SpeechSessionReadiness: Equatable, Sendable {
    case ready
    case speechPermissionDenied
    case microphonePermissionDenied
    case onDeviceRecognitionUnavailable
}

enum AppleSpeechSessionError: LocalizedError, Equatable, Sendable {
    case alreadyRunning
    case speechPermissionDenied
    case microphonePermissionDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case invalidInputFormat
    case audioStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "A speech session is already running."
        case .speechPermissionDenied: return "Speech Recognition permission is required."
        case .microphonePermissionDenied: return "Microphone permission is required."
        case .recognizerUnavailable: return "Apple Speech is unavailable for this language."
        case .onDeviceRecognitionUnavailable:
            return "On-device Apple Speech is unavailable for this language."
        case .invalidInputFormat: return "The selected microphone has no usable input format."
        case .audioStartFailed(let reason): return "Microphone capture failed: \(reason)"
        }
    }
}

@MainActor
protocol SpeechCapturing: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onSpeechStarted: (() -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var isCapturing: Bool { get }
    func start() throws
    func finishUtterance()
    func cancel()
}

@MainActor
final class AppleSpeechSession: SpeechCapturing {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onSpeechStarted: (() -> Void)?
    var onLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var isCapturing = false

    private let locale: Locale
    private let audioEngine: AVAudioEngine
    private let ducker: AudioDucker
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var vad = LockedVoiceActivityDetector()
    private var finishing = false

    init(
        locale: Locale = .current,
        audioEngine: AVAudioEngine = AVAudioEngine(),
        ducker: AudioDucker = AudioDucker()
    ) {
        self.locale = locale
        self.audioEngine = audioEngine
        self.ducker = ducker
    }

    nonisolated static func readiness(
        speechPermission: SpeechPermissionState,
        microphonePermission: SpeechPermissionState,
        supportsOnDevice: Bool
    ) -> SpeechSessionReadiness {
        guard speechPermission == .authorized else {
            return .speechPermissionDenied
        }
        guard microphonePermission == .authorized else {
            return .microphonePermissionDenied
        }
        guard supportsOnDevice else {
            return .onDeviceRecognitionUnavailable
        }
        return .ready
    }

    static var speechPermission: SpeechPermissionState {
        map(SFSpeechRecognizer.authorizationStatus())
    }

    static var microphonePermission: SpeechPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    static func requestSpeechPermission() async -> SpeechPermissionState {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: map(status))
            }
        }
    }

    static func requestMicrophonePermission() async -> SpeechPermissionState {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .authorized : .denied
    }

    func start() throws {
        guard !isCapturing else { throw AppleSpeechSessionError.alreadyRunning }
        guard Self.speechPermission == .authorized else {
            throw AppleSpeechSessionError.speechPermissionDenied
        }
        guard Self.microphonePermission == .authorized else {
            throw AppleSpeechSessionError.microphonePermissionDenied
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw AppleSpeechSessionError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AppleSpeechSessionError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request
        vad.reset()
        finishing = false

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognition(result: result, error: error)
            }
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cancel()
            throw AppleSpeechSessionError.invalidInputFormat
        }

        ducker.snapshotBeforeCapture()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) {
            [weak self, weak request] buffer, _ in
            request?.append(buffer)
            guard let self else { return }
            let rms = Self.rms(of: buffer)
            let duration = Double(buffer.frameLength) / format.sampleRate
            let event = self.vad.consume(rms: rms, frameDuration: duration)
            Task { @MainActor [weak self] in
                self?.onLevel?(rms)
                if event == .speechStarted { self?.onSpeechStarted?() }
                if event == .utteranceEnded { self?.finishUtterance() }
            }
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isCapturing = true
            ducker.duck()
        } catch {
            cancel()
            throw AppleSpeechSessionError.audioStartFailed(error.localizedDescription)
        }
    }

    func finishUtterance() {
        guard isCapturing, !finishing else { return }
        finishing = true
        stopAudioInput()
        recognitionRequest?.endAudio()
    }

    func cancel() {
        stopAudioInput()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        finishing = false
        ducker.restore()
    }

    private func handleRecognition(
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                stopAudioInput()
                recognitionRequest = nil
                recognitionTask = nil
                finishing = false
                ducker.restore()
                onFinal?(text)
            } else {
                onPartial?(text)
            }
        }
        if let error, recognitionTask != nil {
            stopAudioInput()
            recognitionRequest = nil
            recognitionTask = nil
            finishing = false
            ducker.restore()
            onError?(error.localizedDescription)
        }
    }

    private func stopAudioInput() {
        guard isCapturing || audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isCapturing = false
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else { return 0 }
        let samples = UnsafeBufferPointer(
            start: channels[0],
            count: Int(buffer.frameLength)
        )
        let sum = samples.reduce(Float.zero) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
    }

    private static func map(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> SpeechPermissionState {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}

private final class LockedVoiceActivityDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var detector = VoiceActivityDetector()

    func consume(rms: Float, frameDuration: TimeInterval) -> VoiceActivityEvent? {
        lock.lock()
        defer { lock.unlock() }
        return detector.consume(rms: rms, frameDuration: frameDuration)
    }

    func reset() {
        lock.lock()
        detector.reset()
        lock.unlock()
    }
}
