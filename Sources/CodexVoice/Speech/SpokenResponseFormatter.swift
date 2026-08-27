import Foundation

struct SpokenResponse: Equatable, Sendable {
    let text: String
    let omittedTechnicalDetail: Bool
    let wasTruncated: Bool
}

struct SpokenResponseFormatter: Sendable {
    let maximumCharacters: Int

    init(maximumCharacters: Int = 900) {
        self.maximumCharacters = max(1, maximumCharacters)
    }

    func format(_ source: String) -> SpokenResponse {
        var text = source
        var omitted = false

        let withoutFences = replacing(
            #"```[\s\S]*?```"#,
            in: text,
            with: " "
        )
        omitted = withoutFences != text
        text = withoutFences

        let withoutInlineTechnicalSentences = replacing(
            #"(?m)(^|(?<=[.!?])\s+)[^.!?\n]*`[^`]+`[^.!?\n]*[.!?]"#,
            in: text,
            with: " "
        )
        omitted = omitted || withoutInlineTechnicalSentences != text
        text = withoutInlineTechnicalSentences

        let withoutRemainingInlineCode = replacing(#"`[^`]+`"#, in: text, with: " ")
        omitted = omitted || withoutRemainingInlineCode != text
        text = withoutRemainingInlineCode

        text = replacing(#"\[([^\]]+)\]\([^\)]+\)"#, in: text, with: "$1")
        text = replacing(#"https?://\S+"#, in: text, with: " ")
        text = replacing(#"(?m)^\s{0,3}(?:#{1,6}|[-*+]\s+)\s*"#, in: text, with: "")
        text = replacing(#"\s+"#, in: text, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var truncated = false
        if text.count > maximumCharacters {
            text = boundedPrefix(of: text)
            truncated = true
        }

        if truncated {
            text = appendSentence("Full details are available in Codex.", to: text)
        } else if omitted {
            text = appendSentence("See the full technical details in Codex.", to: text)
        }

        return SpokenResponse(
            text: text,
            omittedTechnicalDetail: omitted,
            wasTruncated: truncated
        )
    }

    private func boundedPrefix(of text: String) -> String {
        let boundary = text.index(text.startIndex, offsetBy: maximumCharacters)
        let candidate = text[..<boundary]
        if let end = candidate.lastIndex(where: { ".!?".contains($0) }) {
            return String(candidate[...end]).trimmingCharacters(in: .whitespaces)
        }
        return String(candidate).trimmingCharacters(in: .whitespaces)
    }

    private func appendSentence(_ sentence: String, to text: String) -> String {
        text.isEmpty ? sentence : "\(text) \(sentence)"
    }

    private func replacing(
        _ pattern: String,
        in text: String,
        with template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: template
        )
    }
}
