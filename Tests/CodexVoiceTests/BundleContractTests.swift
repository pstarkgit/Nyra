import Foundation
import Testing
@testable import CodexVoice

@Test func infoPlistDeclaresNyraIdentityAndLocalMicrophonePrivacy() throws {
    let plist = try loadPlist("Config/CodexVoice-Info.plist")

    #expect(plist["CFBundleIdentifier"] as? String == "dev.starkpat.nyra")
    #expect(plist["CFBundleExecutable"] as? String == "Nyra")
    #expect(plist["LSUIElement"] as? Bool == true)
    #expect(plist["LSMinimumSystemVersion"] as? String == "26.0")
    #expect((plist["NSMicrophoneUsageDescription"] as? String)?.localizedCaseInsensitiveContains("on-device") == true)
    #expect(plist["NSSpeechRecognitionUsageDescription"] == nil)
}

@Test func entitlementsDoNotGrantNetworkClientOrAppSandbox() throws {
    let entitlements = try loadPlist("Config/CodexVoice.entitlements")

    #expect(entitlements["com.apple.security.network.client"] == nil)
    #expect(entitlements["com.apple.security.app-sandbox"] == nil)
    #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
    #expect(entitlements["com.apple.security.personal-information.speech-recognition"] == nil)
}

@Test func speechAdapterUsesAnalyzerWithoutLegacySpeechRecognitionTCC() throws {
    let source = try String(
        contentsOf: repositoryRoot().appending(
            path: "Sources/CodexVoice/Speech/AppleSpeechSession.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains("SpeechAnalyzer"))
    #expect(source.contains("SpeechTranscriber"))
    #expect(source.contains("SFSpeechRecognizer") == false)
    #expect(source.contains("requestAuthorization") == false)
}

@Test func packageAndRunScriptsUseCanonicalBundleIdentity() throws {
    let root = repositoryRoot()
    let build = try String(
        contentsOf: root.appending(path: "Scripts/build-app.sh"),
        encoding: .utf8
    )
    let run = try String(
        contentsOf: root.appending(path: "script/build_and_run.sh"),
        encoding: .utf8
    )

    #expect(build.contains("dev.starkpat.nyra"))
    #expect(run.contains("dev.starkpat.nyra"))
    #expect(build.contains("codesign --verify --deep --strict"))
    #expect(build.contains("Developer ID Application: Patrick Stark (P2M5LH6CVA)"))
    #expect(build.contains("--options runtime"))
    #expect(build.contains("--timestamp"))
}

@Test func runtimeUsesAppleTranscriptionAndPollyWithoutTranscribe() throws {
    let root = repositoryRoot()
    let package = try String(
        contentsOf: root.appending(path: "Package.swift"),
        encoding: .utf8
    )
    let runtime = try String(
        contentsOf: root.appending(
            path: "Sources/CodexVoice/App/CodexVoiceApp.swift"
        ),
        encoding: .utf8
    )

    #expect(package.contains("AWSPolly"))
    #expect(package.contains("AWSTranscribe") == false)
    #expect(runtime.contains("capture = AppleSpeechSession()"))
    #expect(runtime.contains("PollySpeechSynthesizer"))
    #expect(runtime.contains("AWSCloudSpeechSession") == false)
}

private func loadPlist(_ relativePath: String) throws -> [String: Any] {
    let data = try Data(contentsOf: repositoryRoot().appending(path: relativePath))
    let value = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(value as? [String: Any])
}

private func repositoryRoot() -> URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
