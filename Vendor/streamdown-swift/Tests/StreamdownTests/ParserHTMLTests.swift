import Testing
@testable import Streamdown

@Test func htmlBlock() {
    let input = """
    <div>
    Hello
    </div>
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first {
        #expect(text.contains("<div>"))
        #expect(text.contains("</div>"))
    } else {
        #expect(Bool(false), "Expected markdown block for HTML")
    }
}

@Test func htmlVoidTag() {
    let input = "<br>"
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first {
        #expect(text == "<br>")
    }
}

@Test func htmlSelfClosingTag() {
    let input = "<img src=\"test.png\" />"
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 1)
    if case .markdown = blocks.first {} else {
        #expect(Bool(false), "Expected markdown for self-closing tag")
    }
}

@Test func htmlWithAttributes() {
    let input = """
    <div class="container" id="main">
    Content
    </div>
    """
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first {
        #expect(text.contains("class=\"container\""))
        #expect(text.contains("</div>"))
    }
}

@Test func nestedDetailsBlock() {
    let input = """
    <details>
    <summary>Outer</summary>
    <details>
    <summary>Inner</summary>
    Inner content
    </details>
    Outer content
    </details>
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first {
        #expect(text.contains("Inner content"))
        #expect(text.contains("Outer content"))
    } else {
        #expect(Bool(false), "Expected single markdown block for nested details")
    }
}

@Test func divInsideDetails() {
    let input = """
    <details>
    <summary>Click me</summary>
    <div class="content">
    Some content
    </div>
    </details>
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first {
        #expect(text.contains("<div"))
        #expect(text.contains("</div>"))
        #expect(text.contains("</details>"))
    } else {
        #expect(Bool(false), "Expected single markdown block for div inside details")
    }
}

@Test func tripleNestedHTML() {
    let input = """
    <details>
    <div>
    <section>
    Deep content
    </section>
    </div>
    </details>
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first {
        #expect(text.contains("Deep content"))
        #expect(text.contains("</details>"))
    } else {
        #expect(Bool(false), "Expected single block for triple-nested HTML")
    }
}

@Test func multipleSiblingDivs() {
    let input = """
    <div>
    <div>First</div>
    <div>Second</div>
    </div>
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first {
        #expect(text.contains("First"))
        #expect(text.contains("Second"))
        #expect(text.hasSuffix("</div>"))
    } else {
        #expect(Bool(false), "Expected single block for sibling divs")
    }
}

@Test func htmlBlockFollowedByMarkdown() {
    let input = """
    <div>
    Hello
    </div>

    Regular paragraph
    """
    let blocks = StreamdownParser.parseBlocks(content: input, mode: .static)
    #expect(blocks.count == 2)
    if case .markdown(let text) = blocks[0] {
        #expect(text.contains("<div>"))
    }
    if case .markdown(let text) = blocks[1] {
        #expect(text.contains("Regular paragraph"))
    }
}

@Test func htmlOpenAndCloseOnSameLine() {
    let input = "<div>Hello</div>"
    let blocks = StreamdownParser.parseBlocks(content: input)
    #expect(blocks.count == 1)
    if case .markdown(let text) = blocks.first {
        #expect(text == "<div>Hello</div>")
    }
}

@Test func htmlIndentationNormalization() {
    let input = "    <div>\n        <p>Hello</p>\n    </div>"
    let result = StreamdownParser.normalizeContent(input, normalizeHtmlIndentation: true)
    #expect(!result.hasPrefix("    "))
}

@Test func htmlIndentationSkippedWhenDisabled() {
    let input = "    <div>\n        <p>Hello</p>\n    </div>"
    let result = StreamdownParser.normalizeContent(input, normalizeHtmlIndentation: false)
    #expect(result == input)
}

@Test func htmlIndentationNoOpForNonHTML() {
    let input = "    just some indented text"
    let result = StreamdownParser.normalizeContent(input, normalizeHtmlIndentation: true)
    #expect(result == input)
}

@Test func regexCacheConsistency() {
    let input = "<div>\ncontent\n</div>"
    let blocks1 = StreamdownParser.parseBlocks(content: input)
    let blocks2 = StreamdownParser.parseBlocks(content: input)
    let blocks3 = StreamdownParser.parseBlocks(content: input)
    #expect(blocks1 == blocks2)
    #expect(blocks2 == blocks3)
}

@Test func regexCacheDifferentTags() {
    let divBlocks = StreamdownParser.parseBlocks(content: "<div>\ncontent\n</div>")
    let detailsBlocks = StreamdownParser.parseBlocks(content: "<details>\ncontent\n</details>")
    let sectionBlocks = StreamdownParser.parseBlocks(content: "<section>\ncontent\n</section>")

    #expect(divBlocks.count == 1)
    #expect(detailsBlocks.count == 1)
    #expect(sectionBlocks.count == 1)
}
