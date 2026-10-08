import Foundation
import Streamdown
import SwiftUI

public actor StreamdownRenderActor {
    private let artificialDelayNanoseconds: UInt64

    public init(artificialDelayNanoseconds: UInt64 = 0) {
        self.artificialDelayNanoseconds = artificialDelayNanoseconds
    }

    func renderSnapshot(
        content: String,
        mode: StreamdownMode,
        parseIncompleteMarkdown: Bool,
        normalizeHtmlIndentation: Bool,
        previous: StreamdownRenderSnapshot?
    ) async -> StreamdownRenderSnapshot {
        if artificialDelayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: artificialDelayNanoseconds)
            } catch {
                return previous ?? .empty
            }
        }

        guard !Task.isCancelled else {
            return previous ?? .empty
        }

        let normalized = StreamdownParser.normalizeContent(
            content,
            normalizeHtmlIndentation: normalizeHtmlIndentation
        )

        let parsedBlocks: [StreamdownParsedBlock]
        let reusedBlockCount: Int

        if let previous,
           normalized.hasPrefix(previous.normalizedContent),
           !previous.parsedBlocks.isEmpty {
            let stableBlocks = Array(previous.parsedBlocks.dropLast())
            let offset = stableBlocks.last?.range.upperBound ?? 0
            let tailContent = normalized.characterSlice(from: offset)
            let tailBlocks = StreamdownParser.parse(
                tailContent,
                mode: mode,
                parseIncompleteMarkdown: parseIncompleteMarkdown
            ).map { $0.offsetting(by: offset) }

            parsedBlocks = stableBlocks + tailBlocks
            reusedBlockCount = stableBlocks.count
        } else {
            parsedBlocks = StreamdownParser.parse(
                normalized,
                mode: mode,
                parseIncompleteMarkdown: parseIncompleteMarkdown
            )
            reusedBlockCount = 0
        }

        let preparedBlocks = prepareBlocks(from: parsedBlocks, previous: previous)

        return StreamdownRenderSnapshot(
            normalizedContent: normalized,
            parsedBlocks: parsedBlocks,
            blocks: preparedBlocks.blocks,
            reusedBlockCount: reusedBlockCount,
            reusedRenderedBlockCount: preparedBlocks.reusedCount
        )
    }

    private func prepareBlocks(
        from parsedBlocks: [StreamdownParsedBlock],
        previous: StreamdownRenderSnapshot?
    ) -> (blocks: [StreamdownRenderedBlock], reusedCount: Int) {
        let previousBlocks = Dictionary(
            uniqueKeysWithValues: (previous?.blocks ?? []).map { ($0.id, $0) }
        )
        var reusedCount = 0

        let blocks = parsedBlocks.map { parsedBlock in
            let blockID: String

            switch parsedBlock.block {
            case .markdown:
                blockID = "markdown-\(parsedBlock.range.lowerBound)"
            case .code:
                blockID = "code-\(parsedBlock.range.lowerBound)"
            case .table:
                blockID = "table-\(parsedBlock.range.lowerBound)"
            }

            if let previousBlock = previousBlocks[blockID],
               Self.canReuse(previousBlock, for: parsedBlock.block) {
                reusedCount += 1
                return previousBlock
            }

            switch parsedBlock.block {
            case let .markdown(source):
                return .markdown(
                    StreamdownMarkdownRenderBlock(
                        id: blockID,
                        source: Self.inertMarkdownSource(source)
                    )
                )
            case let .code(language, code, startLine, isIncomplete):
                return .code(
                    StreamdownCodeRenderBlock(
                        id: blockID,
                        language: language,
                        code: code,
                        startLine: startLine,
                        isIncomplete: isIncomplete
                    )
                )
            case let .table(headers, rows, isIncomplete):
                return .table(
                    StreamdownTableRenderBlock(
                        id: blockID,
                        headers: headers,
                        rows: rows,
                        isIncomplete: isIncomplete,
                        headerInline: headers.map(Self.prepareInlineContent),
                        rowInline: rows.map { $0.map(Self.prepareInlineContent) },
                        columnWeights: Self.columnWeights(headers: headers, rows: rows)
                    )
                )
            }
        }

        return (blocks, reusedCount)
    }

    private static func canReuse(
        _ renderedBlock: StreamdownRenderedBlock,
        for parsedBlock: StreamdownBlock
    ) -> Bool {
        switch (renderedBlock, parsedBlock) {
        case let (.markdown(rendered), .markdown(source)):
            return rendered.source == inertMarkdownSource(source)
        case let (.code(rendered), .code(language, code, startLine, isIncomplete)):
            return rendered.language == language
                && rendered.code == code
                && rendered.startLine == startLine
                && rendered.isIncomplete == isIncomplete
        case let (.table(rendered), .table(headers, rows, isIncomplete)):
            return rendered.headers == headers
                && rendered.rows == rows
                && rendered.isIncomplete == isIncomplete
        default:
            return false
        }
    }

    private static func prepareInlineContent(_ text: String) -> StreamdownInlineContent? {
        guard containsInlineMarkdownSyntax(text) else {
            return nil
        }

        if let parsed = parseInlineMarkdown(text) {
            return StreamdownInlineContent(attributed: parsed)
        }

        let unescaped = unescapedInlineMarkdown(text)
        guard unescaped != text, let parsed = parseInlineMarkdown(unescaped) else {
            return nil
        }
        return StreamdownInlineContent(attributed: parsed)
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    private static func containsInlineMarkdownSyntax(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        var i = text.startIndex
        while i < text.endIndex {
            switch text[i] {
            case "`":
                // Inline code: `content` — require at least 1 non-backtick char
                let next = text.index(after: i)
                if next < text.endIndex {
                    var j = next
                    var hasContent = false
                    while j < text.endIndex {
                        if text[j] == "`" {
                            if hasContent { return true }
                            break
                        }
                        if text[j] == "\n" { break }
                        hasContent = true
                        j = text.index(after: j)
                    }
                    i = j // skip past scanned region
                    continue
                }
            case "*":
                let next = text.index(after: i)
                if next < text.endIndex {
                    if text[next] == "*" {
                        // Bold **content** — require at least 1 non-* char
                        let afterStars = text.index(after: next)
                        if afterStars < text.endIndex {
                            var j = afterStars
                            var hasContent = false
                            while j < text.endIndex {
                                if text[j] == "*" {
                                    let jNext = text.index(after: j)
                                    if jNext < text.endIndex && text[jNext] == "*" {
                                        if hasContent { return true }
                                        break
                                    }
                                }
                                if text[j] == "\n" { break }
                                hasContent = true
                                j = text.index(after: j)
                            }
                            i = j // skip past scanned region
                            continue
                        }
                    } else if text[next] != " " && text[next] != "\n" {
                        // Italic *content* — require at least 1 non-* char
                        var j = next
                        var hasContent = false
                        while j < text.endIndex {
                            if text[j] == "*" {
                                if hasContent { return true }
                                break
                            }
                            if text[j] == "\n" { break }
                            hasContent = true
                            j = text.index(after: j)
                        }
                        i = j // skip past scanned region
                        continue
                    }
                }
            case "~":
                // Strikethrough ~~content~~ — require at least 1 non-~ char
                let next = text.index(after: i)
                if next < text.endIndex && text[next] == "~" {
                    let afterTildes = text.index(after: next)
                    if afterTildes < text.endIndex {
                        var j = afterTildes
                        var hasContent = false
                        while j < text.endIndex {
                            if text[j] == "~" {
                                let jNext = text.index(after: j)
                                if jNext < text.endIndex && text[jNext] == "~" {
                                    if hasContent { return true }
                                    break
                                }
                            }
                            if text[j] == "\n" { break }
                            hasContent = true
                            j = text.index(after: j)
                        }
                        i = j // skip past scanned region
                        continue
                    }
                }
            case "[":
                // Link [text](url) — require content in [] and closing )
                var j = text.index(after: i)
                var hasLinkText = false
                while j < text.endIndex {
                    if text[j] == "]" {
                        let afterBracket = text.index(after: j)
                        if hasLinkText && afterBracket < text.endIndex && text[afterBracket] == "(" {
                            // Scan for closing )
                            var k = text.index(after: afterBracket)
                            while k < text.endIndex {
                                if text[k] == ")" { return true }
                                if text[k] == "\n" { break }
                                k = text.index(after: k)
                            }
                        }
                        break
                    }
                    if text[j] == "\n" { break }
                    hasLinkText = true
                    j = text.index(after: j)
                }
                i = j // skip past scanned region
                continue
            case "_":
                let prev: Character? = i > text.startIndex ? text[text.index(before: i)] : nil
                let next = text.index(after: i)
                if next < text.endIndex {
                    if text[next] == "_" {
                        // __bold__ — require word boundary before opening __
                        if prev == nil || !isWordChar(prev!) {
                            let afterUnderscores = text.index(after: next)
                            if afterUnderscores < text.endIndex {
                                var j = afterUnderscores
                                var hasContent = false
                                while j < text.endIndex {
                                    if text[j] == "_" {
                                        let jNext = text.index(after: j)
                                        if jNext < text.endIndex && text[jNext] == "_" {
                                            // Check word boundary after closing __
                                            let afterClose = text.index(after: jNext)
                                            let afterIsNonWord = afterClose >= text.endIndex
                                                || !isWordChar(text[afterClose])
                                            if hasContent && afterIsNonWord { return true }
                                            break
                                        }
                                    }
                                    if text[j] == "\n" { break }
                                    hasContent = true
                                    j = text.index(after: j)
                                }
                                i = j // skip past scanned region
                                continue
                            }
                        }
                    } else if text[next] != " " && text[next] != "\n" {
                        // _italic_ — require word boundary before opening _
                        if prev == nil || !isWordChar(prev!) {
                            var j = next
                            var hasContent = false
                            while j < text.endIndex {
                                if text[j] == "_" {
                                    // Check word boundary after closing _
                                    let afterClose = text.index(after: j)
                                    let afterIsNonWord = afterClose >= text.endIndex
                                        || !isWordChar(text[afterClose])
                                    if hasContent && afterIsNonWord { return true }
                                    break
                                }
                                if text[j] == "\n" { break }
                                hasContent = true
                                j = text.index(after: j)
                            }
                            i = j // skip past scanned region
                            continue
                        }
                    }
                }
            case "\\":
                // Escape sequences: \*, \_, \`, etc.
                let next = text.index(after: i)
                if next < text.endIndex {
                    switch text[next] {
                    case "*", "_", "`", "[", "]", "(", ")", "~":
                        return true
                    default:
                        break
                    }
                }
            default:
                break
            }
            i = text.index(after: i)
        }

        return false
    }

    private static func parseInlineMarkdown(_ text: String) -> AttributedString? {
        do {
            return try AttributedString(
                markdown: text,
                options: .init(
                    interpretedSyntax: .inlineOnly,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            return nil
        }
    }

    private static func unescapedInlineMarkdown(_ text: String) -> String {
        let scalarPairs: [String: String] = [
            "\\*": "*",
            "\\_": "_",
            "\\`": "`",
            "\\[": "[",
            "\\]": "]",
            "\\(": "(",
            "\\)": ")",
            "\\~": "~",
        ]

        return scalarPairs.reduce(text) { partial, pair in
            partial.replacingOccurrences(of: pair.key, with: pair.value)
        }
    }

    private static func columnWeights(headers: [String], rows: [[String]]) -> [CGFloat] {
        let columnCount = max(headers.count, rows.reduce(0) { max($0, $1.count) })
        guard columnCount > 0 else { return [] }

        return (0..<columnCount).map { index in
            let headerWeight = estimatedContentWeight(headers[safe: index] ?? "")
            let rowWeight = rows.map { row in
                estimatedContentWeight(row[safe: index] ?? "")
            }.max() ?? 1
            return max(headerWeight, rowWeight, 1)
        }
    }

    private static func estimatedContentWeight(_ text: String) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 1 }

        let cappedLength = min(trimmed.count, 120)
        let emphasisBonus = trimmed.contains("**") || trimmed.contains("_") || trimmed.contains("`") ? 2 : 0
        let linkBonus = trimmed.contains("](") ? 4 : 0
        return CGFloat(cappedLength + emphasisBonus + linkBonus)
    }

    private static func inertMarkdownSource(_ source: String) -> String {
        source.replacingOccurrences(of: "<", with: "&lt;")
    }
}
