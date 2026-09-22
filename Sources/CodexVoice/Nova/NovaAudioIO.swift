@preconcurrency import AVFoundation
import Foundation

@MainActor
protocol NovaAudioIOProviding: AnyObject {
    var onInputFrame: ((Data) -> Void)? { get set }
    var onInputLevel: ((Float) -> Void)? { get set }
    var onPlaybackStarted: (() -> Void)? { get set }
    var onPlaybackDrained: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    var voiceProcessingEnabled: Bool { get }

    func start() throws
    func enqueuePlayback(_ data: Data) throws
    func finishPlaybackTurn()
    func clearPlayback()
    func stop()
}

enum NovaAudioIOError: LocalizedError, Equatable {
    case alreadyRunning
    case invalidInputFormat
    case converterUnavailable
    case invalidOutputBuffer
    case voiceProcessingUnavailable
    case audioStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Natural realtime audio is already running."
        case .invalidInputFormat:
            return "The selected microphone has no usable input format."
        case .converterUnavailable:
            return "The selected microphone cannot be converted to Nova audio."
        case .invalidOutputBuffer:
            return "Nova returned an invalid PCM output buffer."
        case .voiceProcessingUnavailable:
            return "macOS voice processing could not be enabled for echo control."
        case .audioStartFailed(let message):
            return "Natural realtime audio failed to start: \(message)"
        }
    }
}

struct NovaPCMFrameAccumulator: Equatable, Sendable {
    let frameByteCount: Int
    private(set) var remainder = Data()

    init(frameByteCount: Int = 1_024) {
        precondition(frameByteCount > 0 && frameByteCount.isMultiple(of: 2))
        self.frameByteCount = frameByteCount
    }

    mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        remainder.append(data)
        var frames: [Data] = []
        while remainder.count >= frameByteCount {
            frames.append(Data(remainder.prefix(frameByteCount)))
            remainder.removeFirst(frameByteCount)
        }
        return frames
    }

    mutating func reset() {
        remainder.removeAll(keepingCapacity: true)
    }
}

struct NovaPCM16AlignmentBuffer: Equatable, Sendable {
    private(set) var remainder = Data()

    mutating func append(_ data: Data) -> Data {
        remainder.append(data)
        let byteCount = remainder.count - remainder.count % 2
        guard byteCount > 0 else { return Data() }
        let aligned = Data(remainder.prefix(byteCount))
        remainder.removeFirst(byteCount)
        return aligned
    }

    mutating func finish() throws {
        guard remainder.isEmpty else { throw PCMStreamPlayerError.incompleteSample }
    }

    mutating func reset() {
        remainder.removeAll(keepingCapacity: true)
    }
}

@MainActor
final class NovaAudioIO: NovaAudioIOProviding {
    var onInputFrame: ((Data) -> Void)?
    var onInputLevel: ((Float) -> Void)?
    var onPlaybackStarted: (() -> Void)?
    var onPlaybackDrained: (() -> Void)?
    var onError: ((String) -> Void)?
    private(set) var voiceProcessingEnabled = false

    private let audioEngine: AVAudioEngine
    private let inputDevices: AudioInputDeviceControlling
    private let playerNode = AVAudioPlayerNode()
    private var playerAttached = false
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!
    private var inputPipeline: NovaInputPipeline?
    private var inputTapInstalled = false
    private var outputAlignment = NovaPCM16AlignmentBuffer()
    private var playbackGeneration: UInt64 = 0
    private var pendingPlaybackBuffers = 0
    private var playbackTurnEnded = false
    private var playbackActive = false

    init(
        audioEngine: AVAudioEngine,
        inputDevices: AudioInputDeviceControlling
    ) {
        self.audioEngine = audioEngine
        self.inputDevices = inputDevices
    }

    func start() throws {
        guard !audioEngine.isRunning, !inputTapInstalled else {
            throw NovaAudioIOError.alreadyRunning
        }
        try inputDevices.prepareForCapture()
        if !playerAttached {
            audioEngine.attach(playerNode)
            audioEngine.connect(
                playerNode,
                to: audioEngine.mainMixerNode,
                format: outputFormat
            )
            playerAttached = true
        }
        let inputNode = audioEngine.inputNode
        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            stop()
            throw NovaAudioIOError.voiceProcessingUnavailable
        }
        voiceProcessingEnabled = inputNode.isVoiceProcessingEnabled
            && audioEngine.outputNode.isVoiceProcessingEnabled
        guard voiceProcessingEnabled else {
            stop()
            throw NovaAudioIOError.voiceProcessingUnavailable
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            stop()
            throw NovaAudioIOError.invalidInputFormat
        }
        guard let pipeline = NovaInputPipeline(inputFormat: inputFormat) else {
            stop()
            throw NovaAudioIOError.converterUnavailable
        }
        inputPipeline = pipeline
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) {
            [weak self, pipeline] buffer, _ in
            let result = pipeline.process(buffer)
            guard !result.frames.isEmpty || result.level > 0 else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onInputLevel?(result.level)
                for frame in result.frames {
                    self.onInputFrame?(frame)
                }
            }
        }
        inputTapInstalled = true
        outputAlignment.reset()
        pendingPlaybackBuffers = 0
        playbackTurnEnded = false
        playbackActive = false
        audioEngine.prepare()
        playerNode.play()
        do {
            try audioEngine.start()
        } catch {
            stop()
            throw NovaAudioIOError.audioStartFailed(error.localizedDescription)
        }
    }

    func enqueuePlayback(_ data: Data) throws {
        let aligned = outputAlignment.append(data)
        guard !aligned.isEmpty else { return }
        let frames = AVAudioFrameCount(aligned.count / 2)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: frames
        ), let channel = buffer.int16ChannelData?[0] else {
            throw NovaAudioIOError.invalidOutputBuffer
        }
        buffer.frameLength = frames
        aligned.copyBytes(to: UnsafeMutableRawBufferPointer(
            start: channel,
            count: aligned.count
        ))

        if !playerNode.isPlaying { playerNode.play() }
        if !playbackActive {
            playbackActive = true
            playbackTurnEnded = false
            onPlaybackStarted?()
        }
        let generation = playbackGeneration
        pendingPlaybackBuffers += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackFinished(generation: generation)
            }
        }
    }

    func finishPlaybackTurn() {
        do {
            try outputAlignment.finish()
            playbackTurnEnded = true
            finishPlaybackIfReady()
        } catch {
            onError?(error.localizedDescription)
            clearPlayback()
        }
    }

    func clearPlayback() {
        playbackGeneration &+= 1
        playerNode.stop()
        playerNode.reset()
        pendingPlaybackBuffers = 0
        playbackTurnEnded = false
        playbackActive = false
        outputAlignment.reset()
        if audioEngine.isRunning { playerNode.play() }
    }

    func stop() {
        playbackGeneration &+= 1
        playerNode.stop()
        playerNode.reset()
        if audioEngine.isRunning { audioEngine.stop() }
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        try? audioEngine.inputNode.setVoiceProcessingEnabled(false)
        voiceProcessingEnabled = false
        if playerAttached {
            audioEngine.disconnectNodeOutput(playerNode)
            audioEngine.detach(playerNode)
            playerAttached = false
        }
        inputPipeline?.reset()
        inputPipeline = nil
        outputAlignment.reset()
        pendingPlaybackBuffers = 0
        playbackTurnEnded = false
        playbackActive = false
        onInputLevel?(0)
    }

    private func playbackFinished(generation: UInt64) {
        guard generation == playbackGeneration else { return }
        pendingPlaybackBuffers = max(0, pendingPlaybackBuffers - 1)
        finishPlaybackIfReady()
    }

    private func finishPlaybackIfReady() {
        guard playbackTurnEnded, pendingPlaybackBuffers == 0 else { return }
        playbackTurnEnded = false
        playbackActive = false
        onPlaybackDrained?()
    }
}

final class NovaInputPipeline: @unchecked Sendable {
    struct Result: Sendable {
        let frames: [Data]
        let level: Float
    }

    private let converter: AVAudioConverter
    private let lock = NSLock()
    private var accumulator = NovaPCMFrameAccumulator()

    init?(inputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(
            from: inputFormat,
            to: Self.outputFormat
        ) else { return nil }
        self.converter = converter
    }

    func process(_ buffer: AVAudioPCMBuffer) -> Result {
        lock.lock()
        defer { lock.unlock() }
        converter.reset()
        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.outputFormat,
            frameCapacity: capacity
        ) else { return Result(frames: [], level: 0) }
        let supply = NovaConverterInputSupply(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            supply.next(status)
        }
        guard status != .error, error == nil,
              let samples = output.int16ChannelData?[0] else {
            return Result(frames: [], level: 0)
        }
        let sampleCount = Int(output.frameLength)
        let data = Data(bytes: samples, count: sampleCount * 2)
        let frames = accumulator.append(data)
        return Result(frames: frames, level: Self.rms(samples, count: sampleCount))
    }

    func reset() {
        lock.lock()
        accumulator.reset()
        lock.unlock()
    }

    private static func rms(_ samples: UnsafePointer<Int16>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        let scale = Float(Int16.max)
        var sum: Float = 0
        for index in 0..<count {
            let sample = Float(samples[index]) / scale
            sum += sample * sample
        }
        return sqrt(sum / Float(count))
    }

    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!
}

private final class NovaConverterInputSupply: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

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
