import Testing
@testable import Streamdown

@Test func fencedCodeBlockWithLanguage() {
    let input = """
    ```swift
    let x = 1
    ```
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks == [.code(language: "swift", code: "let x = 1", startLine: nil, isIncomplete: false)])
}

@Test func fencedCodeBlockNoLanguage() {
    let input = """
    ```
    some code
    ```
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks == [.code(language: nil, code: "some code", startLine: nil, isIncomplete: false)])
}

@Test func fencedCodeBlockWithTilde() {
    let input = """
    ~~~python
    print("hi")
    ~~~
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks == [.code(language: "python", code: "print(\"hi\")", startLine: nil, isIncomplete: false)])
}

@Test func codeBlockWithStartLine() {
    let input = """
    ```swift startLine=5
    let x = 1
    ```
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks == [.code(language: "swift", code: "let x = 1", startLine: 5, isIncomplete: false)])
}

@Test func fourBacktickCodeBlock() {
    let input = """
    ````typescript
    const x = 1
    ````
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks == [.code(language: "typescript", code: "const x = 1", startLine: nil, isIncomplete: false)])
}

@Test func fiveBacktickCodeBlock() {
    let input = """
    `````go
    fmt.Println("hello")
    `````
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks == [.code(language: "go", code: "fmt.Println(\"hello\")", startLine: nil, isIncomplete: false)])
}

@Test func emptyCodeBlock() {
    let input = """
    ```python
    ```
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks == [.code(language: "python", code: "", startLine: nil, isIncomplete: false)])
}

@Test func codeBlockWithLeadingSpaces() {
    let input = "   ```swift\n   let x = 1\n   ```"
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 1)
    if case .code = blocks.first {} else {
        #expect(Bool(false), "Expected code block with leading spaces")
    }
}

@Test func fourBacktickNotClosedByThree() {
    let input = """
    ````python
    some code
    ```
    still code
    ````
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    #expect(blocks.count == 1)
    if case let .code(_, code, _, _) = blocks.first {
        #expect(code.contains("```"))
        #expect(code.contains("still code"))
    } else {
        #expect(Bool(false), "Expected code block")
    }
}

@Test func tildeInsideBacktickFence() {
    let input = """
    ```bash
    ~~~
    echo hi
    ~~~
    ```
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 1)
    if case let .code(_, code, _, _) = blocks.first {
        #expect(code.contains("~~~"))
    } else {
        #expect(Bool(false), "Expected code block containing tildes")
    }
}

@Test func multipleCodeBlocks() {
    let input = """
    ```swift
    let a = 1
    ```

    ```python
    b = 2
    ```
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 3)
    #expect(blocks[0] == .code(language: "swift", code: "let a = 1", startLine: nil, isIncomplete: false))
    if case .markdown = blocks[1] {} else {
        #expect(Bool(false), "Expected markdown between code blocks")
    }
    #expect(blocks[2] == .code(language: "python", code: "b = 2", startLine: nil, isIncomplete: false))
}

@Test func codeBlockMultiline() {
    let input = """
    ```rust
    fn main() {
        println!("Hello");
        let x = 42;
    }
    ```
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 1)
    if case let .code(lang, code, _, _) = blocks.first {
        #expect(lang == "rust")
        let lines = code.components(separatedBy: "\n")
        #expect(lines.count == 4)
    } else {
        #expect(Bool(false), "Expected code block")
    }
}

@Test func incompleteCodeBlockInStreamingMode() {
    let input = """
    ```swift
    let x = 1
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .streaming, parseIncompleteMarkdown: true)
    #expect(blocks == [.code(language: "swift", code: "let x = 1", startLine: nil, isIncomplete: true)])
}

@Test func incompleteCodeBlockInStaticMode() {
    let input = """
    ```swift
    let x = 1
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first {
        #expect(text.contains("```"))
        #expect(text.contains("let x = 1"))
    } else {
        #expect(Bool(false), "Expected markdown block")
    }
}

@Test func incompleteCodeBlockStreamingNoParseIncomplete() {
    let input = """
    ```swift
    let x = 1
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .streaming, parseIncompleteMarkdown: false)
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first {
        #expect(text.contains("```"))
    } else {
        #expect(Bool(false), "Expected markdown block when parseIncompleteMarkdown is false")
    }
}

@Test func onlyCodeFenceMarker() {
    let input = "```"
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    #expect(blocks.count == 1)
    if case .markdown = blocks.first {} else {
        #expect(Bool(false), "Expected markdown for lone fence marker")
    }
}

@Test func twoBackticksNotAFence() {
    let input = "`` not a fence ``"
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first {
        #expect(text == "`` not a fence ``")
    }
}

@Test func codeBlockContainingTableLikeSyntax() {
    let input = """
    ```
    | Not | A | Table |
    | --- | --- | --- |
    | 1 | 2 | 3 |
    ```
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 1)
    if case let .code(_, code, _, _) = blocks.first {
        #expect(code.contains("| Not | A | Table |"))
    } else {
        #expect(Bool(false), "Expected code block, not table")
    }
}
