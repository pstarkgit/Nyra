import Foundation
import Testing
@testable import CodexVoice

@Test func resolvesFirstRegularExecutableCandidate() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let missing = root.appending(path: "missing")
    let executable = root.appending(path: "codex")
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: executable.path
    )

    let result = try CodexBinaryLocator(
        candidateURLs: [missing, executable]
    ).resolve()

    #expect(result.standardizedFileURL == executable.standardizedFileURL)
}

@Test func rejectsDirectoriesAndNonExecutableFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let plain = root.appending(path: "codex")
    try Data("not executable".utf8).write(to: plain)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: plain.path
    )

    #expect(throws: CodexBinaryLocatorError.notFound([root, plain])) {
        try CodexBinaryLocator(candidateURLs: [root, plain]).resolve()
    }
}

@Test func defaultCandidatesPreferDesktopBundleThenExplicitPath() {
    let explicit = URL(filePath: "/opt/codex-custom")
    let candidates = CodexBinaryLocator.defaultCandidateURLs(
        explicitPath: explicit.path,
        environment: ["PATH": "/usr/bin:/bin"]
    )

    #expect(candidates.first?.path == "/Applications/ChatGPT.app/Contents/Resources/codex")
    #expect(candidates.dropFirst().first == explicit)
    #expect(candidates.contains(URL(filePath: "/usr/bin/codex")))
}
