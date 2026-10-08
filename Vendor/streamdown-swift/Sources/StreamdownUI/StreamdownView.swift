import SwiftUI
import MarkdownView
import Streamdown

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - StreamdownView

public struct StreamdownAnimationConfig: Sendable {
    public let enabled: Bool
    public let staggerDelay: TimeInterval

    public init(enabled: Bool = true, staggerDelay: TimeInterval = 0.04) {
        self.enabled = enabled
        self.staggerDelay = staggerDelay
    }

    public static let `default` = StreamdownAnimationConfig()
    public static let none = StreamdownAnimationConfig(enabled: false)
}

public struct StreamdownView: View {
    let content: String
    let mode: StreamdownMode
    let isStreaming: Bool
    let controls: StreamdownControls
    let linkSafety: StreamdownLinkSafetyConfig
    let parseIncompleteMarkdown: Bool
    let normalizeHtmlIndentation: Bool
    let animation: StreamdownAnimationConfig

    @Environment(\.streamdownTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var modalURL: URL?
    @State private var modalIsPresented: Bool = false
    @StateObject private var renderModel = StreamdownRenderModel()
    @State private var visibleBlockIDs: Set<String> = []

    public init(
        content: String,
        isStreaming: Bool = false,
        controls: StreamdownControls = .default,
        parseIncompleteMarkdown: Bool = true,
        normalizeHtmlIndentation: Bool = false,
        linkSafety: StreamdownLinkSafetyConfig = .enabled,
        animation: StreamdownAnimationConfig = .default
    ) {
        self.init(
            content: content,
            mode: isStreaming ? .streaming : .static,
            controls: controls,
            parseIncompleteMarkdown: parseIncompleteMarkdown,
            normalizeHtmlIndentation: normalizeHtmlIndentation,
            linkSafety: linkSafety,
            animation: animation
        )
    }

    public init(
        content: String,
        mode: StreamdownMode,
        controls: StreamdownControls = .default,
        parseIncompleteMarkdown: Bool = true,
        normalizeHtmlIndentation: Bool = false,
        linkSafety: StreamdownLinkSafetyConfig = .enabled,
        animation: StreamdownAnimationConfig = .default
    ) {
        self.content = content
        self.mode = mode
        self.isStreaming = mode == .streaming
        self.controls = controls
        self.parseIncompleteMarkdown = mode == .streaming ? parseIncompleteMarkdown : false
        self.normalizeHtmlIndentation = normalizeHtmlIndentation
        self.linkSafety = linkSafety
        self.animation = animation
    }

    public static func parseBlocks(
        content: String,
        mode: StreamdownMode = .streaming,
        parseIncompleteMarkdown: Bool = true,
        normalizeHtmlIndentation: Bool = false
    ) -> [StreamdownBlock] {
        StreamdownParser.parseBlocks(
            content: content,
            mode: mode,
            parseIncompleteMarkdown: parseIncompleteMarkdown,
            normalizeHtmlIndentation: normalizeHtmlIndentation
        )
    }

    public var body: some View {
        let parseTaskID = StreamdownRenderRequestKey(
            content: content,
            mode: mode,
            parseIncompleteMarkdown: parseIncompleteMarkdown,
            normalizeHtmlIndentation: normalizeHtmlIndentation
        )

        VStack(alignment: .leading, spacing: theme.spacing.md) {
            ForEach(Array(renderModel.snapshot.blocks.enumerated()), id: \.element.id) { index, block in
                Group {
                    switch block {
                    case let .markdown(markdown):
                        markdownBlock(markdown)
                    case let .code(code):
                        codeBlock(
                            language: code.language,
                            code: code.code,
                            startLine: code.startLine,
                            isIncomplete: code.isIncomplete
                        )
                    case let .table(table):
                        tableBlock(table)
                    }
                }
                .opacity(
                    visibleBlockIDs.contains(block.id)
                        ? 1
                        : (animation.enabled && isStreaming && !reduceMotion ? 0 : 1)
                )
                .onAppear {
                    guard
                        animation.enabled,
                        isStreaming,
                        !reduceMotion,
                        !visibleBlockIDs.contains(block.id)
                    else {
                        visibleBlockIDs.insert(block.id)
                        return
                    }
                    let delay = animation.staggerDelay * Double(index)
                    _ = withAnimation(.easeOut(duration: 0.25).delay(delay)) {
                        visibleBlockIDs.insert(block.id)
                    }
                }
            }
        }
        .task(id: parseTaskID) {
            await renderModel.render(
                content: content,
                mode: mode,
                parseIncompleteMarkdown: parseIncompleteMarkdown,
                normalizeHtmlIndentation: normalizeHtmlIndentation
            )
        }
        .onDisappear { renderModel.cancel() }
        .sheet(isPresented: $modalIsPresented) {
            if let pending = modalURL {
                StreamdownLinkSafetyModal(
                    url: pending.absoluteString,
                    isPresented: $modalIsPresented
                ) {
                    openExternalURL(pending)
                }
                #if os(macOS)
                .frame(width: 420, height: 280)
                #endif
            }
        }
        .animation(
            mode == .streaming || !animation.enabled || reduceMotion
                ? nil
                : .easeInOut(duration: 0.2),
            value: renderModel.snapshot.blocks.map(\.id)
        )
    }

    private func markdownBlock(_ block: StreamdownMarkdownRenderBlock) -> some View {
        MarkdownView(block.source)
            .foregroundStyle(theme.colors.foreground)
            .textSelection(.enabled)
            .markdownElementRenderer(
                .image(BlockedRemoteMarkdownImageRenderer(), urlScheme: "http")
            )
            .markdownElementRenderer(
                .image(BlockedRemoteMarkdownImageRenderer(), urlScheme: "https")
            )
            .environment(\.openURL, OpenURLAction { url in
                systemOpenHandler(url)
            })
    }

    private func codeBlock(
        language: String?,
        code: String,
        startLine: Int?,
        isIncomplete: Bool
    ) -> some View {
        let normalizedLanguage = language?.lowercased()
        let isMermaidFlowchart = ["mermaid", "flowchart", "graphviz"].contains(normalizedLanguage)
        let controlsEnabled = isMermaidFlowchart ? controls.mermaid.enabled : controls.code.enabled
        let controlsCopy = controlsEnabled && (isMermaidFlowchart ? controls.mermaid.copy : controls.code.copy)
        let controlsDownload = controlsEnabled && (isMermaidFlowchart ? controls.mermaid.download : controls.code.download)

        if controlsCopy || controlsDownload {
            return AnyView(
                StreamdownCodeBlockView(
                    language: language,
                    code: code,
                    startLine: startLine,
                    isIncomplete: isIncomplete,
                    controlsCopy: controlsCopy,
                    controlsDownload: controlsDownload,
                    isStreaming: isStreaming,
                    showFullscreen: controlsEnabled && isMermaidFlowchart ? controls.mermaid.fullscreen : false,
                    isMermaid: controlsEnabled && isMermaidFlowchart,
                    mermaidPanZoom: controls.mermaid.panZoom,
                    showLineNumbers: controls.code.lineNumbers
                )
            )
        }

        return AnyView(
            VStack(alignment: .leading, spacing: theme.spacing.xs) {
                if let language {
                    Text(language)
                        .font(.caption2)
                        .foregroundStyle(theme.colors.tertiaryLabel)
                        .textCase(.lowercase)
                        .textSelection(.enabled)
                }

                StreamdownCodeBlockContent(
                    language: language,
                    code: code,
                    showHeader: true
                )
                .textSelection(.enabled)
            }
        )
    }

    private func tableBlock(_ block: StreamdownTableRenderBlock) -> some View {
        StreamdownTableView(
            headers: block.headers,
            rows: block.rows,
            headerInline: block.headerInline,
            rowInline: block.rowInline,
            columnWeights: block.columnWeights,
            controls: controls.table,
            isStreaming: isStreaming,
            isIncomplete: block.isIncomplete
        )
    }

    private func systemOpenHandler(_ url: URL) -> OpenURLAction.Result {
        guard linkSafety.enabled else {
            return .systemAction
        }

        if let onLinkCheck = linkSafety.onLinkCheck {
            Task {
                let shouldAllow = await onLinkCheck(url)
                await MainActor.run {
                    if shouldAllow {
                        openExternalURL(url)
                    } else {
                        modalURL = url
                        modalIsPresented = true
                    }
                }
            }
            return .handled
        }

        Task {
            await MainActor.run {
                modalURL = url
                modalIsPresented = true
            }
        }
        return .handled
    }

    private func openExternalURL(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

private struct BlockedRemoteMarkdownImageRenderer: MarkdownImageRenderer {
    func makeBody(configuration: Configuration) -> some View {
        Label(
            configuration.alternativeText ?? "Remote image blocked",
            systemImage: "photo.badge.exclamationmark"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel(
            configuration.alternativeText.map { "Remote image blocked: \($0)" }
                ?? "Remote image blocked"
        )
    }
}

private struct StreamdownRenderRequestKey: Hashable {
    let mode: StreamdownMode
    let parseIncompleteMarkdown: Bool
    let normalizeHtmlIndentation: Bool
    let contentHash: Int
    let contentCount: Int

    init(
        content: String,
        mode: StreamdownMode,
        parseIncompleteMarkdown: Bool,
        normalizeHtmlIndentation: Bool
    ) {
        self.mode = mode
        self.parseIncompleteMarkdown = parseIncompleteMarkdown
        self.normalizeHtmlIndentation = normalizeHtmlIndentation
        self.contentCount = content.count

        var hasher = Hasher()
        hasher.combine(content)
        self.contentHash = hasher.finalize()
    }
}
