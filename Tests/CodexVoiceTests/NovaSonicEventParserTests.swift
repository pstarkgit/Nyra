import Foundation
import Testing
@testable import CodexVoice

@Test func novaInputEventsUseRequiredOrderingAndFormats() throws {
    let ids = NovaSonicSessionIDs(
        promptName: "prompt",
        systemContentName: "system",
        audioContentName: "audio"
    )
    let factory = NovaSonicInputEventFactory(ids: ids, voiceID: "tiffany")
    #expect(factory.openingEvents().compactMap(NovaSonicInputEventFactory.eventName) == [
        "sessionStart", "promptStart", "contentStart", "textInput",
        "contentEnd", "contentStart",
    ])
    #expect(factory.closingEvents().compactMap(NovaSonicInputEventFactory.eventName) == [
        "contentEnd", "promptEnd", "sessionEnd",
    ])

    let session = try payload("sessionStart", in: factory.openingEvents()[0])
    let turn = try #require(session["turnDetectionConfiguration"] as? [String: Any])
    #expect(turn["endpointingSensitivity"] as? String == "HIGH")

    let prompt = try payload("promptStart", in: factory.openingEvents()[1])
    let output = try #require(prompt["audioOutputConfiguration"] as? [String: Any])
    #expect(output["sampleRateHertz"] as? Int == 24_000)
    #expect(output["sampleSizeBits"] as? Int == 16)
    #expect(output["channelCount"] as? Int == 1)
    #expect(output["voiceId"] as? String == "tiffany")

    let audioStart = try payload("contentStart", in: factory.openingEvents()[5])
    let input = try #require(audioStart["audioInputConfiguration"] as? [String: Any])
    #expect(input["sampleRateHertz"] as? Int == 16_000)
    #expect(input["sampleSizeBits"] as? Int == 16)
    #expect(input["channelCount"] as? Int == 1)
}

@Test func novaParserAssemblesFinalUserTranscriptAcrossChunks() throws {
    var parser = NovaSonicEventParser()
    let start = outputEvent("contentStart", [
        "contentId": "user-1",
        "type": "TEXT",
        "role": "USER",
        "additionalModelFields": "{\"generationStage\":\"FINAL\"}",
    ])
    #expect(try parser.parse(start).isEmpty)
    #expect(try parser.parse(outputEvent("textOutput", [
        "contentId": "user-1", "content": "hello ",
    ])) == [.transcriptUpdated(role: .user, text: "hello ", stage: .final)])
    #expect(try parser.parse(outputEvent("textOutput", [
        "contentId": "user-1", "content": "world",
    ])) == [.transcriptUpdated(role: .user, text: "hello world", stage: .final)])
    #expect(try parser.parse(outputEvent("contentEnd", [
        "contentId": "user-1", "type": "TEXT", "stopReason": "PARTIAL_TURN",
    ])) == [.transcriptEnded(
        role: .user,
        text: "hello world",
        stage: .final,
        stopReason: .partialTurn
    )])
}

@Test func novaParserPreservesAssistantStagesAndAudioInterruption() throws {
    var parser = NovaSonicEventParser()
    _ = try parser.parse(outputEvent("contentStart", [
        "contentId": "assistant-preview",
        "type": "TEXT",
        "role": "ASSISTANT",
        "additionalModelFields": "{\"generationStage\":\"SPECULATIVE\"}",
    ]))
    #expect(try parser.parse(outputEvent("textOutput", [
        "contentId": "assistant-preview", "content": "Hi there",
    ])) == [.transcriptUpdated(
        role: .assistant,
        text: "Hi there",
        stage: .speculative
    )])

    _ = try parser.parse(outputEvent("contentStart", [
        "contentId": "audio-1", "type": "AUDIO", "role": "ASSISTANT",
    ]))
    let pcm = Data([1, 2, 3, 4])
    #expect(try parser.parse(outputEvent("audioOutput", [
        "contentId": "audio-1", "content": pcm.base64EncodedString(),
    ])) == [.audio(pcm)])
    #expect(try parser.parse(outputEvent("contentEnd", [
        "contentId": "audio-1", "type": "AUDIO", "stopReason": "INTERRUPTED",
    ])) == [.audioEnded(.interrupted)])
}

@Test func novaParserRejectsOutOfOrderTextAndAudio() {
    var parser = NovaSonicEventParser()
    #expect(throws: NovaSonicEventParserError.textWithoutContentStart("missing")) {
        try parser.parse(outputEvent("textOutput", [
            "contentId": "missing", "content": "late",
        ]))
    }
    #expect(throws: NovaSonicEventParserError.audioWithoutContentStart("missing")) {
        try parser.parse(outputEvent("audioOutput", [
            "contentId": "missing", "content": Data([1, 2]).base64EncodedString(),
        ]))
    }
}

private func outputEvent(_ name: String, _ payload: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["event": [name: payload]])
}

private func payload(_ name: String, in data: Data) throws -> [String: Any] {
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let event = try #require(object["event"] as? [String: Any])
    return try #require(event[name] as? [String: Any])
}
