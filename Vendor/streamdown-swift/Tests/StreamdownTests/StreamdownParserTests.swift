import Testing
@testable import Streamdown

// MARK: - Basic parsing

@Test func emptyInput() {
    let blocks = StreamdownParser.parseBlocks(content: "")
    #expect(blocks.isEmpty)
}

@Test func plainMarkdown() {
    let blocks = StreamdownParser.parseBlocks(content: "Hello world")
    #expect(blocks == [.markdown("Hello world")])
}

@Test func multilineMarkdown() {
    let input = "Line one\nLine two\nLine three"
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks == [.markdown(input)])
}

@Test func whitespaceOnlyContent() {
    let blocks = StreamdownParser.parseBlocks(content: "   \n\n  \n")
    #expect(blocks.count == 1)
    if case .markdown = blocks.first {} else {
        #expect(Bool(false), "Expected markdown block for whitespace-only content")
    }
}

// MARK: - Line ending normalization

@Test func crlfNormalization() {
    let result = StreamdownParser.normalizeContent("a\r\nb", normalizeHtmlIndentation: false)
    #expect(result == "a\nb")
}

@Test func bareCRNormalization() {
    let result = StreamdownParser.normalizeContent("a\rb", normalizeHtmlIndentation: false)
    #expect(result == "a\nb")
}

@Test func mixedLineEndings() {
    let result = StreamdownParser.normalizeContent("a\r\nb\rc\nd", normalizeHtmlIndentation: false)
    #expect(result == "a\nb\nc\nd")
}

// MARK: - Mixed content

@Test func mixedContent() {
    let input = """
    Some text

    ```swift
    let x = 1
    ```

    More text
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 3)
    #expect(blocks[0] == .markdown("Some text\n"))
    #expect(blocks[1] == .code(language: "swift", code: "let x = 1", startLine: nil, isIncomplete: false))
    #expect(blocks[2] == .markdown("\nMore text"))
}

@Test func markdownThenTableThenCode() {
    let input = """
    # Header

    | A | B |
    | --- | --- |
    | 1 | 2 |

    ```js
    console.log("hi")
    ```
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    #expect(blocks.count >= 3)
    if case .markdown(let text) = blocks[0] { #expect(text.contains("# Header")) }
    #expect(blocks.contains { if case .table = $0 { return true }; return false })
    #expect(blocks.contains { if case .code = $0 { return true }; return false })
}

// MARK: - Math blocks

@Test func mathBlockUnclosedInStreaming() {
    let input = """
    Here is math:
    $$
    x^2 + y^2
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .streaming)
    #expect(blocks.count == 1)
    if case .markdown = blocks.first {} else {
        #expect(Bool(false), "Expected markdown block for unclosed math")
    }
}

@Test func mathBlockClosed() {
    let input = "$$\nx^2 + y^2\n$$\nMore text"
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .streaming)
    let totalContent = blocks.compactMap { if case .markdown(let t) = $0 { return t }; return nil }.joined()
    #expect(totalContent.contains("$$"))
    #expect(totalContent.contains("More text"))
}

@Test func escapedDollarSignNotMath() {
    let input = "Price is \\$\\$ per unit"
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .streaming)
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first { #expect(text.contains("\\$")) }
}

@Test func shellDoubleDolorAfterCodeBlock() {
    let input = """
    ```bash
    echo "hello"
    ```

    The process ID is $$ in bash.
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .streaming)
    #expect(blocks.count == 2)
    #expect(blocks[0] == .code(language: "bash", code: "echo \"hello\"", startLine: nil, isIncomplete: false))
    if case .markdown(let text) = blocks[1] { #expect(text.contains("$$")) }
}

@Test func doubleDollarInsideCodeBlockNotMath() {
    let input = "```bash\necho $$\n```"
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .streaming)
    #expect(blocks.count == 1)
    if case let .code(_, code, _, _) = blocks.first { #expect(code.contains("$$")) }
}

// MARK: - Footnotes

@Test func footnotes() {
    let input = "Some text[^1] with a footnote.\n\n[^1]: This is the footnote."
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first { #expect(text.contains("[^1]")) }
}

@Test func footnoteDefinitionOnly() {
    let blocks = StreamdownParser.parseBlocks(content: "[^note]: Definition without reference.")
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first { #expect(text.contains("[^note]:")) }
}

// MARK: - Incremental parse stability

@Test func incrementalParseStableBlocks() {
    let base = "Hello world\n\n```swift\nlet x = 1\n```"
    let blocks1 = StreamdownParser.parseBlocks(content: base, mode: .streaming)
    #expect(blocks1.count == 2)

    let blocks2 = StreamdownParser.parseBlocks(content: base + "\nMore text", mode: .streaming)
    #expect(blocks2.count == 3)
    #expect(blocks2[0] == blocks1[0])
    #expect(blocks2[1] == blocks1[1])
}

@Test func incrementalParseAppendToCodeBlock() {
    let partial = "```swift\nlet x = 1"
    let blocks1 = StreamdownParser.parseBlocks(content: partial, mode: .streaming, parseIncompleteMarkdown: true)
    if case let .code(_, _, _, isIncomplete) = blocks1.first { #expect(isIncomplete == true) }

    let blocks2 = StreamdownParser.parseBlocks(content: partial + "\nlet y = 2\n```", mode: .streaming)
    if case let .code(_, code, _, isIncomplete) = blocks2.first {
        #expect(isIncomplete == false)
        #expect(code.contains("let y = 2"))
    }
}

// MARK: - StreamdownParsedBlock

@Test func parsedBlockOffsetting() {
    let block = StreamdownParsedBlock(block: .markdown("hello"), range: 0..<5)
    let offset = block.offsetting(by: 10)
    #expect(offset.range == 10..<15)
    #expect(offset.block == block.block)
}

@Test func parsedBlockOffsettingByZero() {
    let block = StreamdownParsedBlock(block: .code(language: "swift", code: "x", startLine: nil, isIncomplete: false), range: 5..<10)
    #expect(block.offsetting(by: 0).range == 5..<10)
}

// MARK: - StreamdownBlock identity

@Test func parseBlocksReturnsStreamdownBlockArray() {
    let blocks = StreamdownParser.parseBlocks(content: "hello")
    let _: [StreamdownBlock] = blocks
    #expect(blocks.count == 1)
}

@Test func blockIds() {
    let md = StreamdownBlock.markdown("hello")
    let code = StreamdownBlock.code(language: "swift", code: "x", startLine: nil, isIncomplete: false)
    let table = StreamdownBlock.table(headers: ["A", "B"], rows: [["1", "2"]], isIncomplete: false)
    #expect(md.id.hasPrefix("markdown-"))
    #expect(code.id.hasPrefix("code-"))
    #expect(table.id.hasPrefix("table-"))
    #expect(md.id != StreamdownBlock.markdown("world").id)
}

// MARK: - String.characterSlice

@Test func characterSliceFromZero() { #expect("hello".characterSlice(from: 0) == "hello") }
@Test func characterSliceFromMiddle() { #expect("hello".characterSlice(from: 2) == "llo") }
@Test func characterSliceBeyondLength() { #expect("hello".characterSlice(from: 10) == "") }
@Test func characterSliceExactLength() { #expect("hello".characterSlice(from: 5) == "") }

// MARK: - parse() with ranges

@Test func parseReturnsCorrectRanges() {
    let input = "hello\n```\ncode\n```\nworld"
    let parsed = StreamdownParser.parse(input, mode: .static, parseIncompleteMarkdown: false)
    #expect(parsed.count == 3)
    #expect(parsed[0].range.lowerBound == 0)
    for p in parsed { #expect(p.range.lowerBound < p.range.upperBound) }
}

// MARK: - Unicode

@Test func unicodeContent() {
    let input = "Hello 🌍 世界\n\n```swift\nlet emoji = \"🎉\"\n```"
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 2)
    if case .markdown(let text) = blocks[0] { #expect(text.contains("🌍")) }
    if case let .code(_, code, _, _) = blocks[1] { #expect(code.contains("🎉")) }
}
