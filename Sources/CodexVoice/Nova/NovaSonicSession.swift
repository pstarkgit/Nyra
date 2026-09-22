import AWSBedrockRuntime
import AWSSDKIdentity
import Foundation

protocol NovaSonicStreaming: Sendable {
    func start(voiceID: String) async throws
        -> AsyncThrowingStream<NovaSonicOutputEvent, Error>
    func sendAudio(_ data: Data) async throws
    func stop() async
}

enum NovaSonicSessionError: LocalizedError, Equatable {
    case alreadyActive
    case inactive
    case unsupportedVoice(String)
    case missingOutputStream
    case unknownSDKEvent(String)

    var errorDescription: String? {
        switch self {
        case .alreadyActive:
            return "A Nova 2 Sonic session is already active."
        case .inactive:
            return "The Nova 2 Sonic session is not active."
        case .unsupportedVoice(let voice):
            return "Nova 2 Sonic does not support the voice \(voice)."
        case .missingOutputStream:
            return "Nova 2 Sonic returned no output stream."
        case .unknownSDKEvent(let event):
            return "Nova 2 Sonic returned an unknown SDK event: \(event)"
        }
    }
}

struct NovaSonicSessionIDs: Equatable, Sendable {
    let promptName: String
    let systemContentName: String
    let audioContentName: String

    init(
        promptName: String = UUID().uuidString,
        systemContentName: String = UUID().uuidString,
        audioContentName: String = UUID().uuidString
    ) {
        self.promptName = promptName
        self.systemContentName = systemContentName
        self.audioContentName = audioContentName
    }
}

struct NovaSonicInputEventFactory: Sendable {
    let ids: NovaSonicSessionIDs
    let voiceID: String

    func openingEvents() -> [Data] {
        [
            encode("sessionStart", [
                "inferenceConfiguration": [
                    "maxTokens": 1_024,
                    "topP": 0.9,
                    "temperature": 0.7,
                ],
                "turnDetectionConfiguration": [
                    "endpointingSensitivity": "HIGH"
                ],
            ]),
            encode("promptStart", [
                "promptName": ids.promptName,
                "textOutputConfiguration": ["mediaType": "text/plain"],
                "audioOutputConfiguration": [
                    "mediaType": "audio/lpcm",
                    "sampleRateHertz": 24_000,
                    "sampleSizeBits": 16,
                    "channelCount": 1,
                    "voiceId": voiceID,
                    "encoding": "base64",
                    "audioType": "SPEECH",
                ],
                "toolUseOutputConfiguration": ["mediaType": "application/json"],
                "toolConfiguration": ["tools": []],
            ]),
            encode("contentStart", [
                "promptName": ids.promptName,
                "contentName": ids.systemContentName,
                "type": "TEXT",
                "interactive": false,
                "role": "SYSTEM",
                "textInputConfiguration": ["mediaType": "text/plain"],
            ]),
            encode("textInput", [
                "promptName": ids.promptName,
                "contentName": ids.systemContentName,
                "content": Self.systemPrompt,
            ]),
            encode("contentEnd", [
                "promptName": ids.promptName,
                "contentName": ids.systemContentName,
            ]),
            encode("contentStart", [
                "promptName": ids.promptName,
                "contentName": ids.audioContentName,
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
            ]),
        ]
    }

    func audioEvent(_ audio: Data) -> Data {
        encode("audioInput", [
            "promptName": ids.promptName,
            "contentName": ids.audioContentName,
            "content": audio.base64EncodedString(),
            "role": "USER",
        ])
    }

    func closingEvents() -> [Data] {
        [
            encode("contentEnd", [
                "promptName": ids.promptName,
                "contentName": ids.audioContentName,
            ]),
            encode("promptEnd", ["promptName": ids.promptName]),
            encode("sessionEnd", [:]),
        ]
    }

    static func eventName(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? [String: Any]
        else { return nil }
        return event.keys.sorted().first
    }

    private func encode(_ name: String, _ payload: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["event": [name: payload]])
    }

    private static let systemPrompt = """
    You are Nyra, a natural realtime voice companion. Start with the direct answer. Use warm, concise conversational prose, normally one to three short sentences. Do not expose internal reasoning. This realtime mode is not connected to the user's Codex task, files, commands, or approvals; say so plainly if the user asks for task-aware work.
    """
}

actor NovaSonicSession: NovaSonicStreaming {
    private let configuration: NovaSonicConfiguration
    private var inputContinuation: AsyncThrowingStream<
        BedrockRuntimeClientTypes.InvokeModelWithBidirectionalStreamInput,
        Error
    >.Continuation?
    private var outputTask: Task<Void, Never>?
    private var factory: NovaSonicInputEventFactory?
    private var generation: UInt64 = 0
    private var active = false

    init(configuration: NovaSonicConfiguration = NovaSonicConfiguration()) {
        self.configuration = configuration
    }

    func start(
        voiceID: String
    ) async throws -> AsyncThrowingStream<NovaSonicOutputEvent, Error> {
        guard !active else { throw NovaSonicSessionError.alreadyActive }
        guard NovaSonicVoice.supported.contains(where: { $0.id == voiceID }) else {
            throw NovaSonicSessionError.unsupportedVoice(voiceID)
        }

        let profileResolver = ProfileAWSCredentialIdentityResolver(
            profileName: configuration.profile
        )
        let identity = try await profileResolver.getIdentity()
        let clientConfiguration = try await BedrockRuntimeClient.BedrockRuntimeClientConfig(
            awsCredentialIdentityResolver: StaticAWSCredentialIdentityResolver(identity),
            region: configuration.region
        )
        let client = BedrockRuntimeClient(config: clientConfiguration)
        let (input, continuation) = AsyncThrowingStream<
            BedrockRuntimeClientTypes.InvokeModelWithBidirectionalStreamInput,
            Error
        >.makeStream()
        let factory = NovaSonicInputEventFactory(
            ids: NovaSonicSessionIDs(),
            voiceID: voiceID
        )

        generation &+= 1
        let currentGeneration = generation
        active = true
        self.factory = factory
        inputContinuation = continuation
        for event in factory.openingEvents() {
            continuation.yield(Self.chunk(event))
        }

        let (events, outputContinuation) = AsyncThrowingStream<
            NovaSonicOutputEvent,
            Error
        >.makeStream()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.consume(
                client: client,
                input: input,
                output: outputContinuation,
                generation: currentGeneration
            )
        }
        outputTask = task
        outputContinuation.onTermination = { @Sendable _ in task.cancel() }
        return events
    }

    func sendAudio(_ data: Data) async throws {
        guard active, let inputContinuation, let factory else {
            throw NovaSonicSessionError.inactive
        }
        guard !data.isEmpty else { return }
        inputContinuation.yield(Self.chunk(factory.audioEvent(data)))
    }

    func stop() async {
        generation &+= 1
        active = false
        if let inputContinuation, let factory {
            for event in factory.closingEvents() {
                inputContinuation.yield(Self.chunk(event))
            }
            inputContinuation.finish()
        }
        self.inputContinuation = nil
        self.factory = nil
        let task = outputTask
        outputTask = nil
        if let task {
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                task.cancel()
            }
        }
    }

    private func consume(
        client: BedrockRuntimeClient,
        input: AsyncThrowingStream<
            BedrockRuntimeClientTypes.InvokeModelWithBidirectionalStreamInput,
            Error
        >,
        output: AsyncThrowingStream<NovaSonicOutputEvent, Error>.Continuation,
        generation: UInt64
    ) async {
        do {
            let response = try await client.invokeModelWithBidirectionalStream(
                input: InvokeModelWithBidirectionalStreamInput(
                    body: input,
                    modelId: configuration.modelID
                )
            )
            guard let body = response.body else {
                throw NovaSonicSessionError.missingOutputStream
            }
            var parser = NovaSonicEventParser()
            for try await sdkEvent in body {
                try Task.checkCancellation()
                let data: Data
                switch sdkEvent {
                case .chunk(let payload):
                    guard let bytes = payload.bytes else {
                        throw NovaSonicEventParserError.malformedEvent
                    }
                    data = bytes
                case .sdkUnknown(let event):
                    throw NovaSonicSessionError.unknownSDKEvent(event)
                }
                for event in try parser.parse(data) {
                    output.yield(event)
                }
            }
            output.finish()
        } catch is CancellationError {
            output.finish()
        } catch {
            output.finish(throwing: error)
        }

        if self.generation == generation {
            active = false
            inputContinuation?.finish()
            inputContinuation = nil
            factory = nil
            outputTask = nil
        }
    }

    private static func chunk(
        _ data: Data
    ) -> BedrockRuntimeClientTypes.InvokeModelWithBidirectionalStreamInput {
        .chunk(.init(bytes: data))
    }
}
