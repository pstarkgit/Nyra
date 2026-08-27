import Foundation

enum CodexBinaryLocatorError: Error, Equatable, Sendable {
    case notFound([URL])
}

struct CodexBinaryLocator: Sendable {
    let candidateURLs: [URL]

    init(
        candidateURLs: [URL] = CodexBinaryLocator.defaultCandidateURLs()
    ) {
        self.candidateURLs = candidateURLs
    }

    func resolve(fileManager: FileManager = .default) throws -> URL {
        for candidate in candidateURLs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue,
            fileManager.isExecutableFile(atPath: candidate.path) else {
                continue
            }
            return candidate.standardizedFileURL
        }
        throw CodexBinaryLocatorError.notFound(candidateURLs)
    }

    static func defaultCandidateURLs(
        explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var candidates = [
            URL(filePath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        ]
        if let explicitPath, !explicitPath.isEmpty {
            candidates.append(URL(filePath: explicitPath))
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(filePath: String($0)).appending(path: "codex")
            })
        }
        candidates.append(contentsOf: [
            URL(filePath: NSHomeDirectory()).appending(path: ".toolbox/bin/codex"),
            URL(filePath: "/opt/homebrew/bin/codex"),
            URL(filePath: "/usr/local/bin/codex"),
        ])
        return candidates.reduce(into: []) { result, candidate in
            if !result.contains(candidate) { result.append(candidate) }
        }
    }
}
