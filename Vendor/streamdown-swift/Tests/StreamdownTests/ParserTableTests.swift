import Testing
@testable import Streamdown

@Test func gfmTable() {
    let input = """
    | Name | Age |
    | --- | --- |
    | Alice | 30 |
    | Bob | 25 |
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    let tableBlocks = blocks.filter { if case .table = $0 { return true }; return false }
    #expect(tableBlocks.count == 1)
    if case let .table(headers, rows, isIncomplete) = tableBlocks.first {
        #expect(headers == ["Name", "Age"])
        #expect(rows == [["Alice", "30"], ["Bob", "25"]])
        #expect(isIncomplete == false)
    }
}

@Test func incompleteTableInStreaming() {
    let input = """
    | Name | Age |
    | --- | --- |
    | Alice | 30 |
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .streaming)
    #expect(blocks.count == 1)
    if case let .table(headers, rows, isIncomplete) = blocks.first {
        #expect(headers == ["Name", "Age"])
        #expect(rows == [["Alice", "30"]])
        #expect(isIncomplete == true)
    }
}

@Test func singleColumnNotTable() {
    let input = """
    | Value |
    | --- |
    | one |
    | two |
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    let tableBlocks = blocks.filter { if case .table = $0 { return true }; return false }
    #expect(tableBlocks.isEmpty)
}

@Test func tableWithAlignmentMarkers() {
    let input = """
    | Left | Center | Right |
    | :--- | :---: | ---: |
    | a | b | c |
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    let tableBlocks = blocks.filter { if case .table = $0 { return true }; return false }
    #expect(tableBlocks.count == 1)
    if case let .table(headers, rows, _) = tableBlocks.first {
        #expect(headers == ["Left", "Center", "Right"])
        #expect(rows == [["a", "b", "c"]])
    }
}

@Test func tableWithEscapedPipes() {
    let input = """
    | Code | Output |
    | --- | --- |
    | a \\| b | result |
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    let tableBlocks = blocks.filter { if case .table = $0 { return true }; return false }
    #expect(tableBlocks.count == 1)
    if case let .table(_, rows, _) = tableBlocks.first {
        #expect(rows[0][0] == "a | b")
    }
}

@Test func tableFollowedByMarkdown() {
    let input = """
    | A | B |
    | --- | --- |
    | 1 | 2 |

    Some trailing text
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    #expect(blocks.count == 2)
    if case .table = blocks[0] {} else { #expect(Bool(false), "Expected table as first block") }
    if case .markdown(let text) = blocks[1] { #expect(text.contains("Some trailing text")) }
}

@Test func tableHeadersOnly() {
    let input = """
    | A | B |
    | --- | --- |

    Next paragraph
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    let tableBlocks = blocks.filter { if case .table = $0 { return true }; return false }
    #expect(tableBlocks.count == 1)
    if case let .table(headers, rows, _) = tableBlocks.first {
        #expect(headers == ["A", "B"])
        #expect(rows.isEmpty)
    }
}

@Test func tableRaggedRows() {
    let input = """
    | A | B | C |
    | --- | --- | --- |
    | 1 | 2 |
    | x | y | z |
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    let tableBlocks = blocks.filter { if case .table = $0 { return true }; return false }
    #expect(tableBlocks.count == 1)
    if case let .table(_, rows, _) = tableBlocks.first {
        #expect(rows.count == 2)
        #expect(rows[0].count == 2)
        #expect(rows[1].count == 3)
    }
}

@Test func tableWithInlineMarkdown() {
    let input = """
    | Feature | Status |
    | --- | --- |
    | **Bold** | `done` |
    | _Italic_ | [link](url) |
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    let tableBlocks = blocks.filter { if case .table = $0 { return true }; return false }
    #expect(tableBlocks.count == 1)
    if case let .table(_, rows, _) = tableBlocks.first {
        #expect(rows[0][0] == "**Bold**")
        #expect(rows[0][1] == "`done`")
    }
}

@Test func tableWithoutLeadingPipe() {
    let input = """
    Name | Age
    --- | ---
    Alice | 30
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    let tableBlocks = blocks.filter { if case .table = $0 { return true }; return false }
    #expect(tableBlocks.count == 1)
    if case let .table(headers, rows, _) = tableBlocks.first {
        #expect(headers == ["Name", "Age"])
        #expect(rows == [["Alice", "30"]])
    }
}

@Test func tableWithUnicodeContent() {
    let input = """
    | Emoji | Name |
    | --- | --- |
    | 🍎 | Apple |
    | 🍌 | Banana |
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    let tableBlocks = blocks.filter { if case .table = $0 { return true }; return false }
    #expect(tableBlocks.count == 1)
    if case let .table(_, rows, _) = tableBlocks.first {
        #expect(rows[0][0] == "🍎")
    }
}
