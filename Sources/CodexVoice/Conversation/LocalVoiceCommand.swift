import Foundation

enum LocalVoiceCommand: Equatable, Sendable {
    case stopSpeaking
    case cancelTurn
    case endSession

    static func parse(_ transcript: String) -> LocalVoiceCommand? {
        var normalized = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while let scalar = normalized.unicodeScalars.last,
              CharacterSet.punctuationCharacters.contains(scalar) {
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespaces)
        }

        switch normalized {
        case "stop speaking": return .stopSpeaking
        case "cancel that": return .cancelTurn
        case "end voice session": return .endSession
        default: return nil
        }
    }
}
