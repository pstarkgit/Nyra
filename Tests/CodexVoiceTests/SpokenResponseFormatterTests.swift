import Testing
@testable import CodexVoice

@Test func removesCodeFenceAndFilePathFromSpeech() {
    let formatter = SpokenResponseFormatter(maximumCharacters: 500)

    let result = formatter.format(
        "Done.\n```swift\nprint(\"secret\")\n```\nSee `/tmp/a`."
    )

    #expect(result.text == "Done. See the full technical details in Codex.")
    #expect(result.omittedTechnicalDetail)
}

@Test func keepsMarkdownLinkLabelButDropsURL() {
    let formatter = SpokenResponseFormatter(maximumCharacters: 500)

    let result = formatter.format(
        "Open [the design](https://example.com/design) for details."
    )

    #expect(result.text == "Open the design for details.")
    #expect(result.omittedTechnicalDetail == false)
}

@Test func boundsLongResponseAtSentenceBoundary() {
    let formatter = SpokenResponseFormatter(maximumCharacters: 35)

    let result = formatter.format(
        "The build passed. The detailed migration contains many more steps."
    )

    #expect(result.text == "The build passed. Full details are available in Codex.")
    #expect(result.wasTruncated)
}

@Test func stripsListAndHeadingMarkersWithoutFlatteningWords() {
    let formatter = SpokenResponseFormatter(maximumCharacters: 500)

    let result = formatter.format("# Verdict\n\n- First item\n- Second item")

    #expect(result.text == "Verdict First item Second item")
}
