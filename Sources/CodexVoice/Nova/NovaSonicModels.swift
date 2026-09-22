import Foundation

struct NovaSonicConfiguration: Equatable, Sendable {
    static let defaultProfile = "nyra-nova"
    static let defaultRegion = "us-west-2"
    static let modelID = "amazon.nova-2-sonic-v1:0"

    var profile: String
    var region: String
    var modelID: String

    init(
        profile: String = ProcessInfo.processInfo.environment["NYRA_NOVA_PROFILE"]
            ?? Self.defaultProfile,
        region: String = ProcessInfo.processInfo.environment["NYRA_AWS_REGION"]
            ?? Self.defaultRegion,
        modelID: String = Self.modelID
    ) {
        self.profile = profile
        self.region = region
        self.modelID = modelID
    }
}

struct NovaSonicVoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let locale: String

    var label: String { "\(name) · \(locale)" }

    static let supported: [NovaSonicVoice] = [
        .init(id: "tiffany", name: "Tiffany", locale: "English, US · Polyglot"),
        .init(id: "matthew", name: "Matthew", locale: "English, US · Polyglot"),
        .init(id: "amy", name: "Amy", locale: "English, UK"),
        .init(id: "olivia", name: "Olivia", locale: "English, Australia"),
        .init(id: "kiara", name: "Kiara", locale: "English, India / Hindi"),
        .init(id: "arjun", name: "Arjun", locale: "English, India / Hindi"),
        .init(id: "ambre", name: "Ambre", locale: "French"),
        .init(id: "florian", name: "Florian", locale: "French"),
        .init(id: "beatrice", name: "Beatrice", locale: "Italian"),
        .init(id: "lorenzo", name: "Lorenzo", locale: "Italian"),
        .init(id: "tina", name: "Tina", locale: "German"),
        .init(id: "lennart", name: "Lennart", locale: "German"),
        .init(id: "lupe", name: "Lupe", locale: "Spanish, US"),
        .init(id: "carlos", name: "Carlos", locale: "Spanish, US"),
        .init(id: "carolina", name: "Carolina", locale: "Portuguese, Brazil"),
        .init(id: "leo", name: "Leo", locale: "Portuguese, Brazil"),
    ]

    static let defaultVoice = supported[0]
}

enum NovaTranscriptRole: String, Equatable, Sendable {
    case user = "USER"
    case assistant = "ASSISTANT"
}

enum NovaGenerationStage: String, Equatable, Sendable {
    case speculative = "SPECULATIVE"
    case final = "FINAL"
}

enum NovaContentType: String, Equatable, Sendable {
    case text = "TEXT"
    case audio = "AUDIO"
    case tool = "TOOL"
}

enum NovaStopReason: String, Equatable, Sendable {
    case partialTurn = "PARTIAL_TURN"
    case endTurn = "END_TURN"
    case interrupted = "INTERRUPTED"
    case toolUse = "TOOL_USE"
    case unknown = "UNKNOWN"

    init(rawOrUnknown value: String?) {
        self = value.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

enum NovaConversationState: Equatable, Sendable {
    case idle
    case connecting
    case listening
    case userSpeaking
    case responding
    case speaking
    case ending
    case failed(String)

    var isActive: Bool {
        switch self {
        case .idle, .failed: return false
        case .connecting, .listening, .userSpeaking, .responding, .speaking, .ending:
            return true
        }
    }
}

struct NovaTranscriptEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let role: NovaTranscriptRole
    var text: String

    init(id: UUID = UUID(), role: NovaTranscriptRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

enum NovaSonicOutputEvent: Equatable, Sendable {
    case userSpeechStarted
    case userSpeechEnded
    case transcriptUpdated(
        role: NovaTranscriptRole,
        text: String,
        stage: NovaGenerationStage?
    )
    case transcriptEnded(
        role: NovaTranscriptRole,
        text: String,
        stage: NovaGenerationStage?,
        stopReason: NovaStopReason
    )
    case audio(Data)
    case audioEnded(NovaStopReason)
    case completionEnded(NovaStopReason)
}

enum NovaSonicEventParserError: LocalizedError, Equatable {
    case malformedEvent
    case textWithoutContentStart(String)
    case audioWithoutContentStart(String)
    case invalidBase64Audio

    var errorDescription: String? {
        switch self {
        case .malformedEvent:
            return "Nova 2 Sonic returned a malformed event."
        case .textWithoutContentStart(let id):
            return "Nova text arrived before contentStart for \(id)."
        case .audioWithoutContentStart(let id):
            return "Nova audio arrived before contentStart for \(id)."
        case .invalidBase64Audio:
            return "Nova 2 Sonic returned invalid base64 audio."
        }
    }
}

struct NovaSonicEventParser: Sendable {
    private struct ContentContext: Sendable {
        let role: NovaTranscriptRole?
        let type: NovaContentType
        let stage: NovaGenerationStage?
    }

    private var contexts: [String: ContentContext] = [:]
    private var textBuffers: [String: String] = [:]

    mutating func parse(_ data: Data) throws -> [NovaSonicOutputEvent] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? [String: Any]
        else { throw NovaSonicEventParserError.malformedEvent }

        if event["userSpeechStart"] != nil {
            return [.userSpeechStarted]
        }
        if event["userSpeechEnd"] != nil {
            return [.userSpeechEnded]
        }
        if let start = event["contentStart"] as? [String: Any] {
            guard let id = start["contentId"] as? String,
                  let rawType = start["type"] as? String,
                  let type = NovaContentType(rawValue: rawType)
            else { throw NovaSonicEventParserError.malformedEvent }
            let role = (start["role"] as? String).flatMap(NovaTranscriptRole.init)
            let stage = Self.generationStage(from: start)
            contexts[id] = ContentContext(role: role, type: type, stage: stage)
            if type == .text { textBuffers[id] = "" }
            return []
        }
        if let text = event["textOutput"] as? [String: Any] {
            guard let id = text["contentId"] as? String,
                  let value = text["content"] as? String
            else { throw NovaSonicEventParserError.malformedEvent }
            guard let context = contexts[id], context.type == .text,
                  let role = context.role else {
                throw NovaSonicEventParserError.textWithoutContentStart(id)
            }
            textBuffers[id, default: ""] += value
            return [.transcriptUpdated(
                role: role,
                text: textBuffers[id] ?? "",
                stage: context.stage
            )]
        }
        if let audio = event["audioOutput"] as? [String: Any] {
            guard let id = audio["contentId"] as? String,
                  let encoded = audio["content"] as? String
            else { throw NovaSonicEventParserError.malformedEvent }
            guard let context = contexts[id], context.type == .audio else {
                throw NovaSonicEventParserError.audioWithoutContentStart(id)
            }
            guard let decoded = Data(base64Encoded: encoded) else {
                throw NovaSonicEventParserError.invalidBase64Audio
            }
            return decoded.isEmpty ? [] : [.audio(decoded)]
        }
        if let end = event["contentEnd"] as? [String: Any] {
            guard let id = end["contentId"] as? String,
                  let rawType = end["type"] as? String,
                  let type = NovaContentType(rawValue: rawType)
            else { throw NovaSonicEventParserError.malformedEvent }
            let stopReason = NovaStopReason(rawOrUnknown: end["stopReason"] as? String)
            let context = contexts.removeValue(forKey: id)
            if type == .audio {
                return [.audioEnded(stopReason)]
            }
            if type == .text, let context, let role = context.role {
                let text = textBuffers.removeValue(forKey: id) ?? ""
                return [.transcriptEnded(
                    role: role,
                    text: text,
                    stage: context.stage,
                    stopReason: stopReason
                )]
            }
            return []
        }
        if let end = event["completionEnd"] as? [String: Any] {
            return [.completionEnded(NovaStopReason(
                rawOrUnknown: end["stopReason"] as? String
            ))]
        }
        return []
    }

    mutating func reset() {
        contexts.removeAll(keepingCapacity: true)
        textBuffers.removeAll(keepingCapacity: true)
    }

    private static func generationStage(
        from start: [String: Any]
    ) -> NovaGenerationStage? {
        guard let encoded = start["additionalModelFields"] as? String,
              let data = encoded.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = fields["generationStage"] as? String
        else { return nil }
        return NovaGenerationStage(rawValue: raw)
    }
}
