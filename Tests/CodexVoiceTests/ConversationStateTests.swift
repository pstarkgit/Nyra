import Testing
@testable import CodexVoice

@Test func happyPathReturnsToListening() throws {
    var state = ConversationState.idle
    let events: [ConversationEvent] = [
        .startSession,
        .speechDetected,
        .transcriptionFinalized,
        .turnStarted,
        .turnCompleted,
        .speechFinished,
    ]

    for event in events {
        state = try ConversationTransition.reduce(state: state, event: event)
    }

    #expect(state == .listening)
}

@Test func cannotFinalizeSecondTranscriptWhileWaitingForCodex() {
    #expect(throws: ConversationTransitionError.invalid(
        state: .waitingForCodex,
        event: .transcriptionFinalized
    )) {
        try ConversationTransition.reduce(
            state: .waitingForCodex,
            event: .transcriptionFinalized
        )
    }
}

@Test func approvalReturnsToWaitingForCodex() throws {
    let waiting = try ConversationTransition.reduce(
        state: .waitingForCodex,
        event: .approvalRequested
    )
    #expect(waiting == .awaitingApproval)

    let resumed = try ConversationTransition.reduce(
        state: waiting,
        event: .approvalAnswered
    )
    #expect(resumed == .waitingForCodex)
}

@Test func failureCanRecoverToListening() throws {
    let failed = try ConversationTransition.reduce(
        state: .transcribing,
        event: .fail("Speech stopped")
    )
    #expect(failed == .failed("Speech stopped"))

    let recovered = try ConversationTransition.reduce(
        state: failed,
        event: .recover
    )
    #expect(recovered == .listening)
}

@Test func endSessionReachesIdleFromAnyActiveState() throws {
    let active: [ConversationState] = [
        .listening,
        .transcribing,
        .waitingForCodex,
        .awaitingApproval,
        .speaking,
        .failed("failure"),
    ]

    for state in active {
        let ending = try ConversationTransition.reduce(
            state: state,
            event: .endSession
        )
        #expect(ending == .ending)
        #expect(try ConversationTransition.reduce(
            state: ending,
            event: .sessionEnded
        ) == .idle)
    }
}
