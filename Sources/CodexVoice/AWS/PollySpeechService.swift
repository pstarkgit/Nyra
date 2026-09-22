import AWSPolly
import AWSSDKIdentity
import Foundation

struct PollySpeechConfiguration: Equatable, Sendable {
    static let defaultProfile = "nyra-polly"
    static let defaultRegion = "us-west-2"
    static let defaultVoiceName = "Danielle"

    var profile: String
    var region: String
    var voice: PollyClientTypes.VoiceId
    var engine: PollyClientTypes.Engine

    init(
        profile: String = ProcessInfo.processInfo.environment["NYRA_AWS_PROFILE"]
            ?? Self.defaultProfile,
        region: String = ProcessInfo.processInfo.environment["NYRA_AWS_REGION"]
            ?? Self.defaultRegion,
        voice: PollyClientTypes.VoiceId = .danielle,
        engine: PollyClientTypes.Engine = .generative
    ) {
        self.profile = profile
        self.region = region
        self.voice = voice
        self.engine = engine
    }
}

struct PollyVoiceOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let languageCode: String
    let gender: String

    var label: String {
        "\(name) · \(languageCode) · \(gender)"
    }

    static let danielle = PollyVoiceOption(
        id: PollyClientTypes.VoiceId.danielle.rawValue,
        name: PollySpeechConfiguration.defaultVoiceName,
        languageCode: "en-US",
        gender: "Female"
    )
}

enum PollySpeechServiceError: LocalizedError, Equatable {
    case emptyAudio
    case emptyVoiceCatalog

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "Amazon Polly returned no audio."
        case .emptyVoiceCatalog:
            return "Amazon Polly returned no Generative voices."
        }
    }
}

actor PollySpeechService {
    private let client: PollyClient
    private let configuration: PollySpeechConfiguration

    init(configuration: PollySpeechConfiguration = PollySpeechConfiguration()) throws {
        self.configuration = configuration
        let resolver = ProfileAWSCredentialIdentityResolver(
            profileName: configuration.profile
        )
        let clientConfiguration = try PollyClient.PollyClientConfig(
            awsCredentialIdentityResolver: resolver,
            region: configuration.region
        )
        client = PollyClient(config: clientConfiguration)
    }

    func synthesize(_ text: String) async throws -> Data {
        let input = SynthesizeSpeechInput(
            engine: configuration.engine,
            outputFormat: .mp3,
            sampleRate: "24000",
            text: text,
            textType: .text,
            voiceId: configuration.voice
        )
        let output = try await client.synthesizeSpeech(input: input)
        let data = try await output.audioStream?.readData() ?? Data()
        guard !data.isEmpty else { throw PollySpeechServiceError.emptyAudio }
        return data
    }

    func synthesizeStreaming(
        _ text: String
    ) async throws -> AsyncThrowingStream<Data, Error> {
        // SigV4 event streams form one chained signature sequence. Resolve the
        // MCS-backed profile once so a credential refresh cannot change keys
        // between TextEvent and CloseStreamEvent.
        let profileResolver = ProfileAWSCredentialIdentityResolver(
            profileName: configuration.profile
        )
        let identity = try await profileResolver.getIdentity()
        let pinnedConfiguration = try await PollyClient.PollyClientConfig(
            awsCredentialIdentityResolver: StaticAWSCredentialIdentityResolver(identity),
            region: configuration.region
        )
        let streamingClient = PollyClient(config: pinnedConfiguration)
        let actions = AsyncThrowingStream<
            PollyClientTypes.StartSpeechSynthesisStreamActionStream,
            Error
        > { continuation in
            Task {
                continuation.yield(.textevent(.init(
                    flushStreamConfiguration: .init(force: true),
                    text: text,
                    textType: .text
                )))
                try? await Task.sleep(for: .milliseconds(100))
                continuation.yield(.closestreamevent(.init()))
                continuation.finish()
            }
        }
        let input = StartSpeechSynthesisStreamInput(
            actionStream: actions,
            engine: configuration.engine,
            outputFormat: .pcm,
            sampleRate: "16000",
            voiceId: configuration.voice
        )
        let output = try await streamingClient.startSpeechSynthesisStream(input: input)
        guard let events = output.eventStream else {
            throw PollySpeechServiceError.emptyAudio
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var yieldedAudio = false
                    for try await event in events {
                        switch event {
                        case .audioevent(let audio):
                            if let chunk = audio.audioChunk, !chunk.isEmpty {
                                yieldedAudio = true
                                continuation.yield(chunk)
                            }
                        case .streamclosedevent:
                            break
                        case .sdkUnknown:
                            break
                        }
                    }
                    if yieldedAudio {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: PollySpeechServiceError.emptyAudio)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func availableGenerativeVoices() async throws -> [PollyVoiceOption] {
        var voices: [PollyVoiceOption] = []
        var nextToken: String?

        repeat {
            let output = try await client.describeVoices(input: DescribeVoicesInput(
                engine: .generative,
                includeAdditionalLanguageCodes: true,
                nextToken: nextToken
            ))
            voices.append(contentsOf: (output.voices ?? []).compactMap { voice in
                guard let id = voice.id, let name = voice.name else { return nil }
                return PollyVoiceOption(
                    id: id.rawValue,
                    name: name,
                    languageCode: voice.languageCode?.rawValue ?? "Unknown",
                    gender: voice.gender?.rawValue ?? "Unknown"
                )
            })
            nextToken = output.nextToken
        } while nextToken != nil

        return voices.sorted { left, right in
            let leftRank = Self.languageRank(left.languageCode)
            let rightRank = Self.languageRank(right.languageCode)
            if leftRank != rightRank { return leftRank < rightRank }
            if left.languageCode != right.languageCode {
                return left.languageCode < right.languageCode
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    private static func languageRank(_ code: String) -> Int {
        if code == "en-US" { return 0 }
        if code.hasPrefix("en-") { return 1 }
        return 2
    }
}
