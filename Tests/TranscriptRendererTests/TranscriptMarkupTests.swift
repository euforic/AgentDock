import StreamdownUI
import XCTest

@MainActor
final class TranscriptMarkupTests: XCTestCase {
    func testConversationMarkdownProducesNativeBlockKinds() {
        let markdown = """
        # Result

        Paragraph with **emphasis**, `inline code`, and [a link](https://example.com).

        - First
        - Second

        > Quoted context

        ```swift
        let answer = 42
        ```

        | Name | Value |
        | --- | ---: |
        | answer | 42 |
        """

        let blocks = StreamdownView.parseBlocks(content: markdown, mode: .static)

        XCTAssertTrue(blocks.contains { block in
            if case .markdown = block { return true }
            return false
        })
        XCTAssertTrue(blocks.contains { block in
            if case .code = block { return true }
            return false
        })
        XCTAssertTrue(blocks.contains { block in
            if case .table = block { return true }
            return false
        })
    }

    func testLongFencedCodeRemainsOneBoundedParserBlock() {
        let lines = (0..<10_000).map { "print(\($0))" }.joined(separator: "\n")
        let markdown = "```swift\n\(lines)\n```"

        let blocks = StreamdownView.parseBlocks(content: markdown, mode: .static)

        XCTAssertEqual(blocks.count, 1)
        guard case let .code(language, code, _, _) = blocks[0] else {
            return XCTFail("Expected a code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertTrue(code.contains("print(9999)"))
    }
}
