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

enum PollySpeechServiceError: LocalizedError, Equatable {
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "Amazon Polly returned no audio."
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
}
