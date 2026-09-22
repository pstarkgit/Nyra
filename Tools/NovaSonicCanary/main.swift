import AWSBedrockRuntime
import Darwin
import Foundation

private enum CanaryError: LocalizedError {
    case missingOutputStream
    case malformedOutput
    case unknownStreamEvent(String)
    case noAudio
    case noAssistantTranscript

    var errorDescription: String? {
        switch self {
        case .missingOutputStream:
            return "Nova 2 Sonic returned no output stream."
        case .malformedOutput:
            return "Nova 2 Sonic returned an invalid output event."
        case .unknownStreamEvent(let event):
            return "Nova 2 Sonic returned an unknown SDK stream event: \(event)"
        case .noAudio:
            return "Nova 2 Sonic completed without audio output."
        case .noAssistantTranscript:
            return "Nova 2 Sonic completed without an assistant transcript."
        }
    }
}

private struct CanaryResult: Encodable {
    let modelID: String
    let region: String
    let connectionMilliseconds: Double
    let firstAudioMilliseconds: Double
    let audioBytesObserved: Int
    let userTranscript: String
    let assistantTranscript: String
}

private struct OutputContent {
    let role: String
    let type: String
    let generationStage: String?
}

private final class NovaSonicCanary: @unchecked Sendable {
    private let modelID = "amazon.nova-2-sonic-v1:0"
    private let region = "us-west-2"
    private let promptName = UUID().uuidString
    private let systemContentName = UUID().uuidString
    private let audioContentName = UUID().uuidString

    func run() async throws -> CanaryResult {
        try await runStream()
    }

    private func runStream() async throws -> CanaryResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let (input, continuation) = AsyncThrowingStream<
            BedrockRuntimeClientTypes.InvokeModelWithBidirectionalStreamInput,
            Error
        >.makeStream()
        let defaultFixture = URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/checkouts/aws-sdk-swift/IntegrationTests/Services")
            .appending(path: "AWSBedrockRuntimeIntegrationTests/Resources/japan16k.raw")
        let audioURL = ProcessInfo.processInfo.environment["NYRA_NOVA_CANARY_AUDIO"]
            .map { URL(filePath: $0) } ?? defaultFixture
        let audioData = try Data(contentsOf: audioURL)
        guard !audioData.isEmpty else { throw CanaryError.malformedOutput }

        let client = try BedrockRuntimeClient(region: region)
        let producer = Task {
            continuation.yield(chunk(event: [
                "sessionStart": [
                    "inferenceConfiguration": [
                        "maxTokens": 128,
                        "topP": 0.9,
                        "temperature": 0.7,
                    ],
                    "turnDetectionConfiguration": [
                        "endpointingSensitivity": "HIGH"
                    ],
                ]
            ]))
            continuation.yield(chunk(event: [
                "promptStart": [
                    "promptName": promptName,
                    "textOutputConfiguration": ["mediaType": "text/plain"],
                    "audioOutputConfiguration": [
                        "mediaType": "audio/lpcm",
                        "sampleRateHertz": 24_000,
                        "sampleSizeBits": 16,
                        "channelCount": 1,
                        "voiceId": "tiffany",
                        "encoding": "base64",
                        "audioType": "SPEECH",
                    ],
                    "toolUseOutputConfiguration": ["mediaType": "application/json"],
                    "toolConfiguration": ["tools": []],
                ]
            ]))
            continuation.yield(chunk(event: [
                "contentStart": [
                    "promptName": promptName,
                    "contentName": systemContentName,
                    "type": "TEXT",
                    "interactive": false,
                    "role": "SYSTEM",
                    "textInputConfiguration": ["mediaType": "text/plain"],
                ]
            ]))
            continuation.yield(chunk(event: [
                "textInput": [
                    "promptName": promptName,
                    "contentName": systemContentName,
                    "content": "After recognizing the user, reply with exactly these two words: Canary ready.",
                ]
            ]))
            continuation.yield(chunk(event: [
                "contentEnd": [
                    "promptName": promptName,
                    "contentName": systemContentName,
                ]
            ]))
            continuation.yield(chunk(event: [
                "contentStart": [
                    "promptName": promptName,
                    "contentName": audioContentName,
                    "type": "AUDIO",
                    "interactive": true,
                    "role": "USER",
                    "audioInputConfiguration": [
                        "mediaType": "audio/lpcm",
                        "sampleRateHertz": 16_000,
                        "sampleSizeBits": 16,
                        "channelCount": 1,
                        "audioType": "SPEECH",
                        "encoding": "base64",
                    ],
                ]
            ]))

            for offset in stride(from: 0, to: audioData.count, by: 1_024) {
                try Task.checkCancellation()
                let end = min(offset + 1_024, audioData.count)
                let encoded = audioData[offset..<end].base64EncodedString()
                continuation.yield(chunk(event: [
                    "audioInput": [
                        "promptName": promptName,
                        "contentName": audioContentName,
                        "content": encoded,
                    ]
                ]))
                try await Task.sleep(for: .milliseconds(32))
            }
            continuation.yield(chunk(event: [
                "contentEnd": [
                    "promptName": promptName,
                    "contentName": audioContentName,
                ]
            ]))
        }
        defer {
            producer.cancel()
            continuation.yield(chunk(event: [
                "promptEnd": ["promptName": promptName]
            ]))
            continuation.yield(chunk(event: ["sessionEnd": [:]]))
            continuation.finish()
        }

        let response = try await client.invokeModelWithBidirectionalStream(
            input: InvokeModelWithBidirectionalStreamInput(
                body: input,
                modelId: modelID
            )
        )
        let connectedAt = clock.now
        guard let output = response.body else { throw CanaryError.missingOutputStream }

        var contentByID: [String: OutputContent] = [:]
        var firstAudioAt: ContinuousClock.Instant?
        var audioBytes = 0
        var userTranscript = ""
        var assistantPreviewTranscript = ""
        var assistantFinalTranscript = ""

        for try await sdkEvent in output {
            try Task.checkCancellation()
            let bytes: Data
            switch sdkEvent {
            case .chunk(let payload):
                guard let payloadBytes = payload.bytes else {
                    throw CanaryError.malformedOutput
                }
                bytes = payloadBytes
            case .sdkUnknown(let event):
                throw CanaryError.unknownStreamEvent(event)
            }
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let event = object["event"] as? [String: Any]
            else { throw CanaryError.malformedOutput }

            if ProcessInfo.processInfo.environment["NYRA_NOVA_CANARY_TRACE"] == "1" {
                let name = event.keys.sorted().first ?? "unknown"
                var metadata: [String] = []
                if let start = event["contentStart"] as? [String: Any] {
                    metadata.append("type=\(start["type"] as? String ?? "unknown")")
                    metadata.append("role=\(start["role"] as? String ?? "unknown")")
                    if let stage = generationStage(from: start) {
                        metadata.append("stage=\(stage)")
                    }
                } else if let end = event["contentEnd"] as? [String: Any] {
                    metadata.append("type=\(end["type"] as? String ?? "unknown")")
                    metadata.append("stop=\(end["stopReason"] as? String ?? "unknown")")
                } else if let audio = event["audioOutput"] as? [String: Any],
                          let encoded = audio["content"] as? String {
                    metadata.append("audioBase64Bytes=\(encoded.utf8.count)")
                }
                fputs("event=\(name) \(metadata.joined(separator: " "))\n", stderr)
            }

            if let start = event["contentStart"] as? [String: Any],
               let contentID = start["contentId"] as? String,
               let role = start["role"] as? String,
               let type = start["type"] as? String {
                contentByID[contentID] = OutputContent(
                    role: role,
                    type: type,
                    generationStage: generationStage(from: start)
                )
            } else if let text = event["textOutput"] as? [String: Any],
                      let contentID = text["contentId"] as? String,
                      let content = text["content"] as? String,
                      let metadata = contentByID[contentID] {
                if metadata.role == "USER", metadata.generationStage == "FINAL" {
                    userTranscript += content
                } else if metadata.role == "ASSISTANT",
                          metadata.generationStage == "FINAL" {
                    assistantFinalTranscript += content
                } else if metadata.role == "ASSISTANT" {
                    assistantPreviewTranscript += content
                }
            } else if let audio = event["audioOutput"] as? [String: Any],
                      let encoded = audio["content"] as? String,
                      let decoded = Data(base64Encoded: encoded),
                      !decoded.isEmpty {
                if firstAudioAt == nil { firstAudioAt = clock.now }
                audioBytes += decoded.count
            }

            let assistantText = assistantFinalTranscript.isEmpty
                ? assistantPreviewTranscript : assistantFinalTranscript
            if firstAudioAt != nil,
               !userTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                break
            }
        }

        producer.cancel()
        guard let firstAudioAt else { throw CanaryError.noAudio }
        let finalAssistant = (
            assistantFinalTranscript.isEmpty
                ? assistantPreviewTranscript : assistantFinalTranscript
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalAssistant.isEmpty else { throw CanaryError.noAssistantTranscript }

        return CanaryResult(
            modelID: modelID,
            region: region,
            connectionMilliseconds: milliseconds(startedAt.duration(to: connectedAt)),
            firstAudioMilliseconds: milliseconds(startedAt.duration(to: firstAudioAt)),
            audioBytesObserved: audioBytes,
            userTranscript: userTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
            assistantTranscript: finalAssistant
        )
    }

    private func chunk(
        event: [String: Any]
    ) -> BedrockRuntimeClientTypes.InvokeModelWithBidirectionalStreamInput {
        let data = try! JSONSerialization.data(withJSONObject: ["event": event])
        return .chunk(.init(bytes: data))
    }

    private func generationStage(from start: [String: Any]) -> String? {
        guard let encoded = start["additionalModelFields"] as? String,
              let data = encoded.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return fields["generationStage"] as? String
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

@main
private enum Main {
    static func main() async {
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled else { return }
            fputs("Nova Sonic canary failed: process deadline exceeded.\n", stderr)
            fflush(stderr)
            Darwin._exit(124)
        }

        do {
            let result = try await NovaSonicCanary().run()
            watchdog.cancel()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(result)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            fflush(stdout)
            Darwin._exit(EXIT_SUCCESS)
        } catch {
            watchdog.cancel()
            fputs("Nova Sonic canary failed: \(error.localizedDescription)\n", stderr)
            fflush(stderr)
            Darwin._exit(EXIT_FAILURE)
        }
    }
}
