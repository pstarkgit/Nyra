import Foundation

enum ConversationState: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case waitingForCodex
    case awaitingApproval
    case speaking
    case ending
    case failed(String)
}

enum ConversationEvent: Equatable, Sendable {
    case startSession
    case speechDetected
    case transcriptionFinalized
    case discardTranscript
    case beginSteering
    case turnStarted
    case approvalRequested
    case approvalAnswered
    case turnCompleted
    case speechFinished
    case fail(String)
    case recover
    case endSession
    case sessionEnded
}

enum ConversationTransitionError: Error, Equatable, Sendable {
    case invalid(state: ConversationState, event: ConversationEvent)
}

enum ConversationTransition {
    static func reduce(
        state: ConversationState,
        event: ConversationEvent
    ) throws -> ConversationState {
        switch (state, event) {
        case (.idle, .startSession):
            return .listening
        case (.listening, .speechDetected):
            return .transcribing
        case (.transcribing, .transcriptionFinalized):
            return .waitingForCodex
        case (.transcribing, .discardTranscript):
            return .listening
        case (.waitingForCodex, .beginSteering):
            return .transcribing
        case (.waitingForCodex, .turnStarted):
            return .waitingForCodex
        case (.waitingForCodex, .approvalRequested):
            return .awaitingApproval
        case (.awaitingApproval, .approvalAnswered):
            return .waitingForCodex
        case (.waitingForCodex, .turnCompleted):
            return .speaking
        case (.speaking, .speechFinished):
            return .listening
        case (.failed, .recover):
            return .listening
        case (.ending, .sessionEnded):
            return .idle
        case (.idle, .endSession):
            return .idle
        case (_, .fail(let message)) where state != .idle && state != .ending:
            return .failed(message)
        case (_, .endSession) where state != .idle && state != .ending:
            return .ending
        default:
            throw ConversationTransitionError.invalid(state: state, event: event)
        }
    }
}
