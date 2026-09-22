@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import CodexVoice

@Test func novaPCMFramesAreExactlyThirtyTwoMilliseconds() {
    var accumulator = NovaPCMFrameAccumulator()
    let source = Data((0..<2_500).map { UInt8($0 % 251) })
    let first = accumulator.append(source.prefix(700))
    #expect(first.isEmpty)
    let rest = accumulator.append(source.dropFirst(700))
    #expect(rest.map(\.count) == [1_024, 1_024])
    #expect(accumulator.remainder.count == 452)
    #expect(Data(rest.joined()) + accumulator.remainder == source)
}

@Test func novaPCMFrameResetDropsStaleAudio() {
    var accumulator = NovaPCMFrameAccumulator()
    _ = accumulator.append(Data(repeating: 7, count: 800))
    accumulator.reset()
    #expect(accumulator.remainder.isEmpty)
    #expect(accumulator.append(Data(repeating: 9, count: 1_024)) == [
        Data(repeating: 9, count: 1_024),
    ])
}

@Test func novaPCMAlignmentCarriesOnlyIncompleteSamples() throws {
    var alignment = NovaPCM16AlignmentBuffer()
    #expect(alignment.append(Data([1])).isEmpty)
    #expect(alignment.append(Data([2, 3, 4])) == Data([1, 2, 3, 4]))
    try alignment.finish()

    #expect(alignment.append(Data([5, 6, 7])) == Data([5, 6]))
    #expect(throws: PCMStreamPlayerError.incompleteSample) {
        try alignment.finish()
    }
    alignment.reset()
    try alignment.finish()
}

@Test func novaInputPipelineConvertsFortyEightKHzFloatToSixteenKHzPCM() throws {
    let inputFormat = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    ))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: inputFormat,
        frameCapacity: 4_800
    ))
    buffer.frameLength = 4_800
    let channel = try #require(buffer.floatChannelData?[0])
    for index in 0..<4_800 {
        channel[index] = sin(Float(index) * 0.04) * 0.25
    }

    let pipeline = try #require(NovaInputPipeline(inputFormat: inputFormat))
    let result = pipeline.process(buffer)

    #expect(!result.frames.isEmpty)
    #expect(result.frames.allSatisfy { $0.count == 1_024 })
    #expect(result.level > 0.05)
    #expect(result.level < 0.30)
}
