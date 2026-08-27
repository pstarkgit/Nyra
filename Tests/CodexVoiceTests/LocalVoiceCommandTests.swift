import Testing
@testable import CodexVoice

@Test func parsesExactCommandsIgnoringCaseAndTerminalPunctuation() {
    #expect(LocalVoiceCommand.parse(" Stop speaking! ") == .stopSpeaking)
    #expect(LocalVoiceCommand.parse("CANCEL THAT.") == .cancelTurn)
    #expect(LocalVoiceCommand.parse("end voice session?") == .endSession)
}

@Test func doesNotConsumeNormalRequestsContainingCommandWords() {
    #expect(LocalVoiceCommand.parse("Stop speaking so quickly next time") == nil)
    #expect(LocalVoiceCommand.parse("Can you cancel that timer in the app?") == nil)
    #expect(LocalVoiceCommand.parse("How does end voice session work?") == nil)
}

@Test func doesNotTreatEmptyInputAsCommand() {
    #expect(LocalVoiceCommand.parse("  ...  ") == nil)
}
