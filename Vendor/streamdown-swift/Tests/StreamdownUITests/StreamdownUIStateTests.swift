import Streamdown
import SwiftUI
import Testing
@testable import StreamdownUI

#if os(macOS)
import AppKit
import Network
#endif

@MainActor
@Test func renderModelPublishesParsedMarkdown() async {
    let model = StreamdownRenderModel()

    await model.render(
        content: "Hello **world**",
        mode: .static,
        parseIncompleteMarkdown: false,
        normalizeHtmlIndentation: false
    )

    for _ in 0..<100 where model.snapshot.blocks.isEmpty {
        try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(model.snapshot.blocks.count == 1)
}

@Test func renderActorKeepsMarkdownSourceAndReusesStableBlocks() async {
    let actor = StreamdownRenderActor()
    let initialContent = """
    Intro 1 < 2 with **emphasis**.

    ```swift
    let value = 1
    ```

    Tail
    """
    let initial = await actor.renderSnapshot(
        content: initialContent,
        mode: .streaming,
        parseIncompleteMarkdown: true,
        normalizeHtmlIndentation: false,
        previous: nil
    )

    guard case let .markdown(intro) = initial.blocks.first else {
        Issue.record("Expected the first rendered block to remain markdown")
        return
    }
    #expect(intro.source == "Intro 1 &lt; 2 with **emphasis**.\n")

    let updated = await actor.renderSnapshot(
        content: initialContent + " extended",
        mode: .streaming,
        parseIncompleteMarkdown: true,
        normalizeHtmlIndentation: false,
        previous: initial
    )

    #expect(updated.reusedBlockCount == 2)
    #expect(updated.reusedRenderedBlockCount == 2)
}

@Test func renderActorMakesTranscriptHTMLInertBeforeRendering() async {
    let actor = StreamdownRenderActor()
    let snapshot = await actor.renderSnapshot(
        content: """
        <script>fetch("https://example.invalid/leak")</script>
        <img src="https://example.invalid/pixel">
        """,
        mode: .static,
        parseIncompleteMarkdown: true,
        normalizeHtmlIndentation: false,
        previous: nil
    )

    let renderedSource = snapshot.blocks.compactMap { block -> String? in
        guard case let .markdown(markdown) = block else { return nil }
        return markdown.source
    }.joined(separator: "\n")

    #expect(!renderedSource.contains("<script"))
    #expect(!renderedSource.contains("<img"))
    #expect(renderedSource.contains("&lt;script>"))
    #expect(renderedSource.contains("&lt;img"))
}

@Test func renderActorPreservesNonHTMLMarkdownAndExactStructuredPayloads() async {
    let actor = StreamdownRenderActor()
    let markdownSnapshot = await actor.renderSnapshot(
        content: "[safe link](https://example.invalid) &copy; 1 < 2",
        mode: .static,
        parseIncompleteMarkdown: true,
        normalizeHtmlIndentation: false,
        previous: nil
    )
    let codeSnapshot = await actor.renderSnapshot(
        content: "```html\n<script>literal code</script>\n```",
        mode: .static,
        parseIncompleteMarkdown: true,
        normalizeHtmlIndentation: false,
        previous: nil
    )
    let tableSnapshot = await actor.renderSnapshot(
        content: "| key | value |\n| --- | --- |\n| safe | literal & cell |\n",
        mode: .static,
        parseIncompleteMarkdown: true,
        normalizeHtmlIndentation: false,
        previous: nil
    )

    let markdown = markdownSnapshot.blocks.compactMap { block -> StreamdownMarkdownRenderBlock? in
        guard case let .markdown(markdown) = block else { return nil }
        return markdown
    }.first
    let code = codeSnapshot.blocks.compactMap { block -> StreamdownCodeRenderBlock? in
        guard case let .code(code) = block else { return nil }
        return code
    }.first
    let table = tableSnapshot.blocks.compactMap { block -> StreamdownTableRenderBlock? in
        guard case let .table(table) = block else { return nil }
        return table
    }.first

    guard let markdown, let code, let table else {
        Issue.record("Expected Markdown, code, and table blocks")
        return
    }

    #expect(markdown.source.contains("[safe link](https://example.invalid)"))
    #expect(markdown.source.contains("&copy;"))
    #expect(markdown.source.contains("1 &lt; 2"))
    #expect(code.code == "<script>literal code</script>")
    #expect(table.rows == [["safe", "literal & cell"]])
}

@Test func renderActorPreservesRemoteImageMarkdownForTheBlockingRenderer() async {
    let actor = StreamdownRenderActor()
    let snapshot = await actor.renderSnapshot(
        content: "![tracking pixel](https://example.invalid/pixel.png)",
        mode: .static,
        parseIncompleteMarkdown: true,
        normalizeHtmlIndentation: false,
        previous: nil
    )

    guard case let .markdown(markdown) = snapshot.blocks.first else {
        Issue.record("Expected remote image syntax to remain in a Markdown block")
        return
    }
    #expect(markdown.source.contains("https://example.invalid/pixel.png"))
}

#if os(macOS)
@MainActor
@Test func remoteMarkdownImageDoesNotOpenNetworkConnection() async throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let connections = AcceptedConnectionCounter()
    listener.newConnectionHandler = { connection in
        connections.record()
        connection.cancel()
    }
    listener.start(queue: DispatchQueue(label: "StreamdownUITests.RemoteImageListener"))
    defer { listener.cancel() }

    for _ in 0..<100 where listener.port == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let port = try #require(listener.port)

    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = NSHostingView(
        rootView: StreamdownView(
            content: "![probe](http://127.0.0.1:\(port.rawValue)/pixel)"
        )
        .frame(width: 480, height: 320)
    )
    window.orderFront(nil)
    defer { window.close() }

    try await Task.sleep(for: .milliseconds(750))
    #expect(connections.count == 0)
}

private final class AcceptedConnectionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
        lock.withLock { storage }
    }

    func record() {
        lock.withLock {
            storage += 1
        }
    }
}
#endif

@MainActor
@Test func codeBlockStatePublishesUpdatedContent() async {
    let state = CodeBlockRenderState(code: "let value = 1", language: "swift")

    state.update(code: "let value = 2", language: "swift")

    for _ in 0..<100 where state.lineTexts != ["let value = 2"] {
        try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(state.normalizedCode == "let value = 2")
    #expect(state.lineTexts == ["let value = 2"])
    #expect(state.renderVersion > 1)
}

@MainActor
@Test func codeBlockStatePublishesThemeChanges() async {
    let state = CodeBlockRenderState(code: "// note", language: "swift")
    let initialVersion = state.renderVersion

    state.updateAppearance(foreground: .red, secondaryLabel: .blue)

    for _ in 0..<100 where state.renderVersion == initialVersion {
        try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(state.renderVersion > initialVersion)
}
