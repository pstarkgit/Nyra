@preconcurrency import AVFoundation
import CoreMedia
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
    case microphonePermissionDenied
    case onDeviceRecognitionUnavailable
}

enum AppleSpeechSessionError: LocalizedError, Equatable, Sendable {
    case alreadyRunning
    case microphonePermissionDenied
    case analyzerUnavailable
    case localeUnavailable
    case invalidInputFormat
    case converterUnavailable
    case audioStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "A speech session is already running."
        case .microphonePermissionDenied: return "Microphone permission is required."
        case .analyzerUnavailable: return "Apple on-device speech analysis is unavailable."
        case .localeUnavailable: return "No installed Apple speech language matches this Mac."
        case .invalidInputFormat: return "The selected microphone has no usable input format."
        case .converterUnavailable: return "The microphone audio format cannot be converted."
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

    private let audioEngine: AVAudioEngine
    private let ducker: AudioDucking
    private var sessionTask: Task<Void, Never>?
    private var analyzerInput: AsyncStream<AnalyzerInput>.Continuation?
    private var finishSignal: CaptureFinishSignal?
    private var vad = LockedVoiceActivityDetector()
    private var generation: UInt64 = 0
    private var tapInstalled = false

    init(
        audioEngine: AVAudioEngine = AVAudioEngine(),
        ducker: AudioDucking = AudioDucker(duckVolume: 1.0)
    ) {
        self.audioEngine = audioEngine
        self.ducker = ducker
    }

    nonisolated static func readiness(
        microphonePermission: SpeechPermissionState,
        supportsOnDevice: Bool
    ) -> SpeechSessionReadiness {
        guard microphonePermission == .authorized else {
            return .microphonePermissionDenied
        }
        return supportsOnDevice ? .ready : .onDeviceRecognitionUnavailable
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

    static func requestMicrophonePermission() async -> SpeechPermissionState {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .authorized : .denied
    }

    func start() throws {
        guard sessionTask == nil else { throw AppleSpeechSessionError.alreadyRunning }
        guard Self.microphonePermission == .authorized else {
            throw AppleSpeechSessionError.microphonePermissionDenied
        }
        guard SpeechTranscriber.isAvailable else {
            throw AppleSpeechSessionError.analyzerUnavailable
        }
        generation &+= 1
        let sessionGeneration = generation
        ducker.snapshotBeforeCapture()
        vad.reset()
        sessionTask = Task { [weak self] in
            await self?.runAnalyzer(generation: sessionGeneration)
        }
    }

    func finishUtterance() {
        guard sessionTask != nil else { return }
        stopAudioInput()
        analyzerInput?.finish()
        if let finishSignal {
            Task { await finishSignal.finish() }
        }
        ducker.restore()
    }

    func cancel() {
        generation &+= 1
        stopAudioInput()
        analyzerInput?.finish()
        if let finishSignal {
            Task { await finishSignal.finish() }
        }
        sessionTask?.cancel()
        sessionTask = nil
        analyzerInput = nil
        finishSignal = nil
        ducker.restore()
    }

    private func runAnalyzer(generation: UInt64) async {
        do {
            let locale = try await Self.preferredInstalledLocale()
            let transcriber = SpeechTranscriber(
                locale: locale,
                preset: Self.progressivePreset
            )
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await request.downloadAndInstall()
            }
            try Task.checkCancellation()

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let signal = CaptureFinishSignal()
            let accumulator = AnalyzerTranscriptAccumulator()

            let producer = Task {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    let text = await accumulator.consume(
                        result.text,
                        range: result.range
                    )
                    await MainActor.run { [weak self] in
                        guard self?.generation == generation else { return }
                        self?.onPartial?(text)
                    }
                }
            }

            await withTaskCancellationHandler {
                do {
                    try await analyzer.start(inputSequence: stream)
                    try await MainActor.run { [weak self] in
                        guard let self, self.generation == generation else {
                            throw CancellationError()
                        }
                        self.analyzerInput = continuation
                        self.finishSignal = signal
                        try self.startAudioInput(
                            continuation: continuation,
                            generation: generation
                        )
                    }
                    await signal.wait()
                    continuation.finish()
                    try Task.checkCancellation()
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                    try await producer.value
                    let final = await accumulator.text
                    await MainActor.run { [weak self] in
                        self?.complete(text: final, generation: generation)
                    }
                } catch {
                    producer.cancel()
                    await analyzer.cancelAndFinishNow()
                    await MainActor.run { [weak self] in
                        self?.fail(error, generation: generation)
                    }
                }
            } onCancel: {
                continuation.finish()
                producer.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            await MainActor.run { [weak self] in
                self?.fail(error, generation: generation)
            }
        }
    }

    private func startAudioInput(
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        generation: UInt64
    ) throws {
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AppleSpeechSessionError.invalidInputFormat
        }
        guard let converter = AVAudioConverter(
            from: inputFormat,
            to: Self.analyzerAudioFormat
        ) else {
            throw AppleSpeechSessionError.converterUnavailable
        }
        let converterBox = AudioConverterBox(converter)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            let samples = Self.convert(
                buffer: buffer,
                using: converterBox.converter,
                to: Self.analyzerAudioFormat
            )
            guard !samples.isEmpty else { return }
            let rms = Self.rms(samples: samples)
            let duration = Double(samples.count) / Self.analyzerAudioFormat.sampleRate
            continuation.yield(AnalyzerInput(buffer: Self.buffer(from: samples)))
            let event = self.vad.consume(rms: rms, frameDuration: duration)
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.onLevel?(rms)
                if event == .speechStarted { self.onSpeechStarted?() }
                if event == .utteranceEnded { self.finishUtterance() }
            }
        }
        tapInstalled = true
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isCapturing = true
            ducker.duck()
        } catch {
            stopAudioInput()
            throw AppleSpeechSessionError.audioStartFailed(error.localizedDescription)
        }
    }

    private func complete(text: String, generation: UInt64) {
        guard self.generation == generation else { return }
        stopAudioInput()
        ducker.restore()
        sessionTask = nil
        analyzerInput = nil
        finishSignal = nil
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            onError?("Apple on-device speech did not recognize an utterance.")
        } else {
            onFinal?(text)
        }
    }

    private func fail(_ error: Error, generation: UInt64) {
        guard self.generation == generation else { return }
        stopAudioInput()
        ducker.restore()
        sessionTask = nil
        analyzerInput = nil
        finishSignal = nil
        if !(error is CancellationError) {
            onError?(error.localizedDescription)
        }
    }

    private func stopAudioInput() {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        isCapturing = false
    }

    private static var progressivePreset: SpeechTranscriber.Preset {
        let base = SpeechTranscriber.Preset.timeIndexedProgressiveTranscription
        return SpeechTranscriber.Preset(
            transcriptionOptions: base.transcriptionOptions,
            reportingOptions: base.reportingOptions,
            attributeOptions: base.attributeOptions.union([.audioTimeRange])
        )
    }

    private static let analyzerAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private static func preferredInstalledLocale() async throws -> Locale {
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.isEmpty else { throw AppleSpeechSessionError.localeUnavailable }
        let current = Locale.current
        if let exact = installed.first(where: {
            $0.identifier.replacingOccurrences(of: "-", with: "_")
                == current.identifier.replacingOccurrences(of: "-", with: "_")
        }) {
            return exact
        }
        let language = current.language.languageCode?.identifier ?? "en"
        return installed.first(where: {
            $0.language.languageCode?.identifier == language
        }) ?? installed.first(where: {
            $0.language.languageCode?.identifier == "en"
        }) ?? installed[0]
    }

    private nonisolated static func buffer(from samples: [Int16]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.int16ChannelData![0].update(
                from: source.baseAddress!,
                count: samples.count
            )
        }
        return buffer
    }

    private nonisolated static func convert(
        buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> [Int16] {
        converter.reset()
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: capacity
        ) else { return [] }
        let supply = ConverterInputSupply(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            supply.next(status)
        }
        guard status != .error, error == nil,
              let channel = output.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(
            start: channel[0],
            count: Int(output.frameLength)
        ))
    }

    private nonisolated static func rms(samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let scale = Float(Int16.max)
        let sum = samples.reduce(Float.zero) {
            let normalized = Float($1) / scale
            return $0 + normalized * normalized
        }
        return sqrt(sum / Float(samples.count))
    }
}

private final class AudioConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter
    init(_ converter: AVAudioConverter) { self.converter = converter }
}

private final class ConverterInputSupply: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(
        _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        guard !supplied else {
            status.pointee = .endOfStream
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
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

private actor CaptureFinishSignal {
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if finished { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let waiter = waiter
        self.waiter = nil
        waiter?.resume()
    }
}

private actor AnalyzerTranscriptAccumulator {
    private var accumulator = AppleLiveTranscriptAccumulator()

    var text: String { accumulator.text }

    func consume(_ text: AttributedString, range: CMTimeRange) -> String {
        accumulator.consume(text, range: range)
    }
}

private struct AppleLiveTranscriptAccumulator: Sendable {
    private var transcript = AttributedString()

    var text: String { String(transcript.characters) }

    mutating func consume(
        _ text: AttributedString,
        range: CMTimeRange
    ) -> String {
        let replacement = Self.timeIndexed(text, fallbackRange: range)
        if let replaced = transcript.rangeOfAudioTimeRangeAttributes(
            intersecting: range
        ) {
            transcript.replaceSubrange(replaced, with: replacement)
        } else {
            transcript.append(replacement)
        }
        return self.text
    }

    private static func timeIndexed(
        _ text: AttributedString,
        fallbackRange: CMTimeRange
    ) -> AttributedString {
        let runRanges = text.runs.map(\.audioTimeRange)
        var indexed = AttributedString()
        for (index, run) in text.runs.enumerated() {
            var fragment = AttributedString(text[run.range])
            if run.audioTimeRange == nil {
                var attributes = AttributeContainer()
                attributes[
                    AttributeScopes.SpeechAttributes.TimeRangeAttribute.self
                ] = inferredTimeRange(
                    at: index,
                    runRanges: runRanges,
                    fallbackRange: fallbackRange
                )
                fragment.mergeAttributes(attributes)
            }
            indexed.append(fragment)
        }
        return indexed
    }

    private static func inferredTimeRange(
        at index: Int,
        runRanges: [CMTimeRange?],
        fallbackRange: CMTimeRange
    ) -> CMTimeRange {
        let fallbackEnd = CMTimeRangeGetEnd(fallbackRange)
        let previousEnd = runRanges.prefix(index).reversed().compactMap { $0 }
            .first.map(CMTimeRangeGetEnd)
        let nextStart = runRanges.dropFirst(index + 1).compactMap { $0 }.first?.start
        let start = CMTimeCompare(
            fallbackRange.start,
            previousEnd ?? fallbackRange.start
        ) >= 0 ? fallbackRange.start : previousEnd!
        let end = CMTimeCompare(fallbackEnd, nextStart ?? fallbackEnd) <= 0
            ? fallbackEnd : nextStart!
        guard CMTimeCompare(end, start) > 0 else { return fallbackRange }
        return CMTimeRange(start: start, duration: CMTimeSubtract(end, start))
    }
}
