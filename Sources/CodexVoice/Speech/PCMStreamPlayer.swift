@preconcurrency import AVFoundation
import Foundation

enum PCMStreamPlayerError: LocalizedError, Equatable {
    case invalidAudioBuffer
    case incompleteSample

    var errorDescription: String? {
        switch self {
        case .invalidAudioBuffer:
            return "The streaming audio buffer is invalid."
        case .incompleteSample:
            return "The streaming audio ended with an incomplete PCM sample."
        }
    }
}

@MainActor
final class PCMStreamPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var completion: CheckedContinuation<Void, Error>?
    private var carry = Data()
    private var pendingBuffers = 0
    private var streamEnded = false
    private var generation: UInt64 = 0

    private(set) var isPlaying = false

    init(sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1) {
        format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func play(_ stream: AsyncThrowingStream<Data, Error>) async throws {
        if isPlaying { stop() }
        generation &+= 1
        let currentGeneration = generation
        carry.removeAll(keepingCapacity: true)
        pendingBuffers = 0
        streamEnded = false

        engine.prepare()
        try engine.start()
        node.play()
        isPlaying = true

        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    for try await chunk in stream {
                        guard currentGeneration == self.generation else { return }
                        try self.schedule(chunk, generation: currentGeneration)
                    }
                    guard currentGeneration == self.generation else { return }
                    self.streamEnded = true
                    if !self.carry.isEmpty {
                        self.fail(
                            PCMStreamPlayerError.incompleteSample,
                            generation: currentGeneration
                        )
                    } else {
                        self.finishIfReady(generation: currentGeneration)
                    }
                } catch {
                    self.fail(error, generation: currentGeneration)
                }
            }
        }
    }

    func stop() {
        generation &+= 1
        node.stop()
        engine.stop()
        isPlaying = false
        carry.removeAll(keepingCapacity: true)
        pendingBuffers = 0
        streamEnded = false
        let completion = completion
        self.completion = nil
        completion?.resume(throwing: CancellationError())
    }

    private func schedule(_ chunk: Data, generation: UInt64) throws {
        guard !chunk.isEmpty else { return }
        carry.append(chunk)
        let byteCount = carry.count - (carry.count % MemoryLayout<Int16>.size)
        guard byteCount > 0 else { return }

        let frames = AVAudioFrameCount(byteCount / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frames
        ), let channel = buffer.int16ChannelData?[0] else {
            throw PCMStreamPlayerError.invalidAudioBuffer
        }
        buffer.frameLength = frames
        let audio = Data(carry.prefix(byteCount))
        let destination = UnsafeMutableRawBufferPointer(
            start: channel,
            count: byteCount
        )
        audio.copyBytes(to: destination)
        carry.removeFirst(byteCount)

        pendingBuffers += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.bufferFinished(generation: generation)
            }
        }
    }

    private func bufferFinished(generation: UInt64) {
        guard generation == self.generation else { return }
        pendingBuffers = max(0, pendingBuffers - 1)
        finishIfReady(generation: generation)
    }

    private func finishIfReady(generation: UInt64) {
        guard generation == self.generation,
              streamEnded,
              pendingBuffers == 0 else { return }
        node.stop()
        engine.stop()
        isPlaying = false
        let completion = completion
        self.completion = nil
        completion?.resume()
    }

    private func fail(_ error: Error, generation: UInt64) {
        guard generation == self.generation else { return }
        node.stop()
        engine.stop()
        isPlaying = false
        carry.removeAll(keepingCapacity: true)
        pendingBuffers = 0
        streamEnded = false
        let completion = completion
        self.completion = nil
        completion?.resume(throwing: error)
    }
}
