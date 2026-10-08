import Foundation

public struct StreamdownParser: Sendable {
    struct LineInfo {
        let text: String
        let start: Int
        let end: Int
    }

    struct CodeFenceInfo {
        let fence: String
        let language: String?
        let startLine: Int?
    }

    // MARK: - Regex Pattern Cache

    private static let patternCacheLock = NSLock()
    nonisolated(unsafe) private static var openTagPatternCache: [String: NSRegularExpression] = [:]
    nonisolated(unsafe) private static var closeTagPatternCache: [String: NSRegularExpression] = [:]

    static func cachedOpenTagPattern(for tag: String) -> NSRegularExpression? {
        let key = tag.lowercased()
        patternCacheLock.lock()
        defer { patternCacheLock.unlock() }
        if let cached = openTagPatternCache[key] {
            return cached
        }
        let escapedTag = NSRegularExpression.escapedPattern(for: key)
        guard let regex = try? NSRegularExpression(
            pattern: "<\\s*\(escapedTag)\\b[^>]*>",
            options: [.caseInsensitive]
        ) else { return nil }
        openTagPatternCache[key] = regex
        return regex
    }

    static func cachedCloseTagPattern(for tag: String) -> NSRegularExpression? {
        let key = tag.lowercased()
        patternCacheLock.lock()
        defer { patternCacheLock.unlock() }
        if let cached = closeTagPatternCache[key] {
            return cached
        }
        let escapedTag = NSRegularExpression.escapedPattern(for: key)
        guard let regex = try? NSRegularExpression(
            pattern: "</\\s*\(escapedTag)\\b[^>]*>",
            options: [.caseInsensitive]
        ) else { return nil }
        closeTagPatternCache[key] = regex
        return regex
    }

    // MARK: - Public API

    public static func normalizeContent(
        _ content: String,
        normalizeHtmlIndentation: Bool
    ) -> String {
        let normalizedInput = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        guard normalizeHtmlIndentation else {
            return normalizedInput
        }

        guard let startPattern = try? NSRegularExpression(pattern: "^[ \\t]*<[\\w!/?-]") else {
            return normalizedInput
        }
        let full = normalizedInput as NSString
        guard startPattern.numberOfMatches(
            in: normalizedInput,
            options: [],
            range: NSRange(location: 0, length: full.length)
        ) > 0 else {
            return normalizedInput
        }

        guard let regex = try? NSRegularExpression(
            pattern: "(^|\\n)[ \\t]{4,}(?=<[\\w!/?-])",
            options: []
        ) else {
            return normalizedInput
        }

        let range = NSRange(location: 0, length: full.length)
        return regex.stringByReplacingMatches(
            in: normalizedInput,
            options: [],
            range: range,
            withTemplate: "$1"
        )
    }

    public static func parse(
        _ normalized: String,
        mode: StreamdownMode,
        parseIncompleteMarkdown: Bool
    ) -> [StreamdownParsedBlock] {
        if normalized.isEmpty {
            return []
        }

        if containsFootnote(normalized) {
            return [
                StreamdownParsedBlock(
                    block: .markdown(normalized),
                    range: 0..<normalized.count
                )
            ]
        }

        let isStreaming = mode == .streaming
        let effectiveParseIncomplete = isStreaming ? parseIncompleteMarkdown : false
        let lines = lineInfos(in: normalized)

        var index = 0
        var blocks: [StreamdownParsedBlock] = []
        var currentMarkdown: [String] = []
        var currentMarkdownStartLine: Int?
        var currentMarkdownHasUnclosedMathBlock = false
        var previousBlockWasCode = false

        func flushMarkdown(upTo lastLineIndex: Int) {
            guard let startLine = currentMarkdownStartLine, !currentMarkdown.isEmpty else { return }
            blocks.append(
                StreamdownParsedBlock(
                    block: .markdown(currentMarkdown.joined(separator: "\n")),
                    range: lines[startLine].start..<lines[lastLineIndex].end
                )
            )
            currentMarkdown.removeAll(keepingCapacity: true)
            currentMarkdownStartLine = nil
            currentMarkdownHasUnclosedMathBlock = false
        }

        while index < lines.count {
            let line = lines[index].text

            if !currentMarkdown.isEmpty {
                if isStreaming
                    && !previousBlockWasCode
                    && currentMarkdownHasUnclosedMathBlock {
                    currentMarkdown.append(line)
                    updateMathBlockState(
                        with: line,
                        hasUnclosedMathBlock: &currentMarkdownHasUnclosedMathBlock
                    )
                    index += 1
                    continue
                }
            }

            if let htmlBlock = parseHTMLBlock(lines: lines, startIndex: &index) {
                if currentMarkdownStartLine != nil {
                    flushMarkdown(upTo: index - htmlBlock.lineCount - 1)
                }
                blocks.append(
                    StreamdownParsedBlock(
                        block: .markdown(htmlBlock.text),
                        range: htmlBlock.start..<htmlBlock.end
                    )
                )
                previousBlockWasCode = false
                continue
            }

            if let codeInfo = parseCodeFenceStart(line: line) {
                if currentMarkdownStartLine != nil {
                    flushMarkdown(upTo: index - 1)
                }

                let blockStart = lines[index].start
                index += 1
                var codeLines: [String] = []
                var foundEnd = false

                while index < lines.count {
                    if isCodeFenceEnd(lines[index].text, fence: codeInfo.fence) {
                        foundEnd = true
                        index += 1
                        break
                    }

                    codeLines.append(lines[index].text)
                    index += 1
                }

                let code = codeLines.joined(separator: "\n")
                let isIncomplete = isStreaming && !foundEnd
                let blockEndLine = max(0, min(index - 1, lines.count - 1))
                let blockRange = blockStart..<lines[blockEndLine].end

                if !foundEnd && !effectiveParseIncomplete {
                    blocks.append(
                        StreamdownParsedBlock(
                            block: .markdown(codeInfo.fence + "\n" + code),
                            range: blockRange
                        )
                    )
                    previousBlockWasCode = false
                    continue
                }

                blocks.append(
                    StreamdownParsedBlock(
                        block: .code(
                            language: codeInfo.language,
                            code: code,
                            startLine: codeInfo.startLine,
                            isIncomplete: isIncomplete
                        ),
                        range: blockRange
                    )
                )
                previousBlockWasCode = true
                continue
            }

            if let table = parseTable(lines: lines, startIndex: index, isStreaming: isStreaming) {
                if currentMarkdownStartLine != nil {
                    flushMarkdown(upTo: index - 1)
                }
                blocks.append(
                    StreamdownParsedBlock(
                        block: table.block,
                        range: lines[index].start..<lines[table.nextIndex - 1].end
                    )
                )
                index = table.nextIndex
                previousBlockWasCode = false
                continue
            }

            if currentMarkdownStartLine == nil {
                currentMarkdownStartLine = index
            }
            currentMarkdown.append(line)
            updateMathBlockState(
                with: line,
                hasUnclosedMathBlock: &currentMarkdownHasUnclosedMathBlock
            )
            index += 1
            previousBlockWasCode = false
        }

        if let startLine = currentMarkdownStartLine, !currentMarkdown.isEmpty {
            blocks.append(
                StreamdownParsedBlock(
                    block: .markdown(currentMarkdown.joined(separator: "\n")),
                    range: lines[startLine].start..<lines[lines.count - 1].end
                )
            )
        }

        return blocks
    }

    public static func parseBlocks(
        content: String,
        mode: StreamdownMode = .streaming,
        parseIncompleteMarkdown: Bool = true,
        normalizeHtmlIndentation: Bool = false
    ) -> [StreamdownBlock] {
        let normalized = normalizeContent(content, normalizeHtmlIndentation: normalizeHtmlIndentation)
        return parse(normalized, mode: mode, parseIncompleteMarkdown: parseIncompleteMarkdown).map(\.block)
    }

    // MARK: - Footnote Detection

    /// Scans for `[^` followed by 1–200 word/hyphen characters and a closing `]`,
    /// optionally followed by `:` for definitions. Matches the same tokens as the
    /// old regex patterns without the overhead.
    private static func containsFootnote(_ text: String) -> Bool {
        let chars = Array(text.unicodeScalars)
        let count = chars.count
        var i = 0
        while i < count - 2 {
            if chars[i] == "[" && chars[i + 1] == "^" {
                var j = i + 2
                var labelLen = 0
                while j < count && labelLen < 200 {
                    let c = chars[j]
                    if c == "]" { break }
                    let isWordOrHyphen = c == "-"
                        || (c >= "a" && c <= "z")
                        || (c >= "A" && c <= "Z")
                        || (c >= "0" && c <= "9")
                        || c == "_"
                    if !isWordOrHyphen { break }
                    labelLen += 1
                    j += 1
                }
                if labelLen >= 1 && j < count && chars[j] == "]" {
                    return true
                }
            }
            i += 1
        }
        return false
    }

    // MARK: - Line splitting

    static func lineInfos(in content: String) -> [LineInfo] {
        var lines: [LineInfo] = []
        var lineStartIndex = content.startIndex
        var lineStartOffset = 0
        var currentOffset = 0
        var index = content.startIndex

        while index < content.endIndex {
            let character = content[index]
            if character == "\n" {
                lines.append(
                    LineInfo(
                        text: String(content[lineStartIndex..<index]),
                        start: lineStartOffset,
                        end: currentOffset + 1
                    )
                )
                index = content.index(after: index)
                currentOffset += 1
                lineStartIndex = index
                lineStartOffset = currentOffset
                continue
            }

            currentOffset += 1
            index = content.index(after: index)
        }

        lines.append(
            LineInfo(
                text: String(content[lineStartIndex..<content.endIndex]),
                start: lineStartOffset,
                end: currentOffset
            )
        )

        return lines
    }
}

public extension String {
    func characterSlice(from offset: Int) -> String {
        guard offset > 0 else { return self }
        guard offset < count else { return "" }
        let start = index(startIndex, offsetBy: offset)
        return String(self[start...])
    }
}
