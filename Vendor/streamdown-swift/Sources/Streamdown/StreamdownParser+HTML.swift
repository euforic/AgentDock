import Foundation

extension StreamdownParser {
    static func parseHTMLBlock(
        lines: [LineInfo],
        startIndex: inout Int
    ) -> (text: String, start: Int, end: Int, lineCount: Int)? {
        guard startIndex < lines.count else { return nil }

        let firstLine = lines[startIndex].text
        guard let openingTag = htmlBlockStartTag(in: firstLine) else {
            return nil
        }

        if htmlVoidTags.contains(openingTag.lowercased()) {
            let start = lines[startIndex].start
            let end = lines[startIndex].end
            startIndex += 1
            return (firstLine, start, end, 1)
        }

        var htmlLines: [String] = [firstLine]
        let blockStart = lines[startIndex].start
        let initialIndex = startIndex
        startIndex += 1
        var openTags: [String] = [openingTag.lowercased()]

        while startIndex < lines.count && !openTags.isEmpty {
            let line = lines[startIndex].text
            htmlLines.append(line)

            // Check for new nested block-level tags opening on this line
            if let nestedTag = htmlBlockStartTag(in: line) {
                let nestedLower = nestedTag.lowercased()
                if !htmlVoidTags.contains(nestedLower) {
                    let nestedOpenCount = countNonSelfClosingOpenTags(line: line, tag: nestedLower)
                    let nestedCloseCount = countClosingTags(line: line, tag: nestedLower)
                    let netNested = nestedOpenCount - nestedCloseCount
                    if netNested > 0 {
                        openTags.append(contentsOf: Array(repeating: nestedLower, count: netNested))
                        startIndex += 1
                        continue
                    }
                }
            }

            guard let currentTag = openTags.last else {
                break
            }

            let openCount = countNonSelfClosingOpenTags(line: line, tag: currentTag)
            if openCount > 0 {
                openTags.append(contentsOf: Array(repeating: currentTag, count: openCount))
            }

            let closeCount = countClosingTags(line: line, tag: currentTag)
            if closeCount > 0 {
                for _ in 0..<closeCount where openTags.last == currentTag {
                    openTags.removeLast()
                }
            }

            startIndex += 1
        }

        let blockEndIndex = min(max(startIndex - 1, initialIndex), lines.count - 1)
        return (
            htmlLines.joined(separator: "\n"),
            blockStart,
            lines[blockEndIndex].end,
            blockEndIndex - initialIndex + 1
        )
    }

    static func htmlBlockStartTag(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.hasPrefix("<"),
              !trimmed.hasPrefix("</"),
              !trimmed.hasPrefix("<!"),
              !trimmed.hasPrefix("<?") else {
            return nil
        }

        var tag = ""
        var index = trimmed.startIndex

        guard trimmed[index] == "<" else {
            return nil
        }

        index = trimmed.index(after: index)
        if index == trimmed.endIndex {
            return nil
        }

        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character.isWhitespace || character == ">" || character == "/" {
                break
            }
            if character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_") {
                tag.append(character.lowercased())
            } else {
                break
            }
            index = trimmed.index(after: index)
        }

        guard !tag.isEmpty else {
            return nil
        }

        let selfClosing = trimmed.hasSuffix("/>")
        if selfClosing {
            return nil
        }

        return tag
    }

    static let htmlVoidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img",
        "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    static func countNonSelfClosingOpenTags(line: String, tag: String) -> Int {
        guard !htmlVoidTags.contains(tag.lowercased()) else { return 0 }

        guard let regex = cachedOpenTagPattern(for: tag) else { return 0 }

        let nsLine = line as NSString
        let matches = regex.matches(
            in: line,
            range: NSRange(location: 0, length: nsLine.length)
        )

        var count = 0
        for match in matches {
            let matched = nsLine.substring(with: match.range)
            if matched.hasSuffix("/>") || matched.hasSuffix(" />") {
                continue
            }
            count += 1
        }
        return count
    }

    static func countClosingTags(line: String, tag: String) -> Int {
        guard let regex = cachedCloseTagPattern(for: tag) else { return 0 }

        let nsLine = line as NSString
        return regex.numberOfMatches(
            in: line,
            range: NSRange(location: 0, length: nsLine.length)
        )
    }
}
