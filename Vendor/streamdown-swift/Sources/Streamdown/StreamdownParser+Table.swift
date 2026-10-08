extension StreamdownParser {
    static func parseTable(
        lines: [LineInfo],
        startIndex: Int,
        isStreaming: Bool
    ) -> (block: StreamdownBlock, nextIndex: Int)? {
        guard startIndex + 1 < lines.count else { return nil }

        let headerLine = lines[startIndex].text
        let separatorLine = lines[startIndex + 1].text

        guard headerLine.contains("|"), isSeparatorRow(separatorLine) else {
            return nil
        }

        let headers = parseTableRow(headerLine)
        guard headers.count >= 2 else {
            return nil
        }

        var index = startIndex + 2
        var rows: [[String]] = []

        while index < lines.count {
            let line = lines[index].text
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !line.contains("|") {
                break
            }

            let row = parseTableRow(line)
            if row.isEmpty {
                break
            }

            rows.append(row)
            index += 1
        }

        let onlyTrailingWhitespaceLines = index < lines.count && lines[index...].allSatisfy {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let preservesStreamingTableTail = isStreaming && rows.isEmpty && onlyTrailingWhitespaceLines
        let nextIndex = preservesStreamingTableTail ? lines.count : index
        let isIncomplete = isStreaming && (nextIndex >= lines.count)
        return (
            .table(headers: headers, rows: rows, isIncomplete: isIncomplete),
            nextIndex
        )
    }

    static func isSeparatorRow(_ line: String) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        if trimmedLine.isEmpty { return false }

        let parts = parseTableRow(trimmedLine)
        if parts.count < 2 { return false }

        return parts.allSatisfy { value in
            let token = value.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty, token.contains("-") else { return false }
            return token.allSatisfy { character in
                character == "-" || character == ":"
            }
        }
    }

    static func parseTableRow(_ line: String) -> [String] {
        var normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadTrailingPipe = normalized.hasSuffix("|")

        if normalized.hasPrefix("|") {
            normalized.removeFirst()
        }
        if normalized.hasSuffix("|") {
            normalized.removeLast()
        }

        if normalized.isEmpty {
            return []
        }

        var cells: [String] = []
        var current = ""
        var isEscaped = false

        for char in normalized {
            if isEscaped {
                current.append(char)
                isEscaped = false
                continue
            }

            if char == "\\" {
                isEscaped = true
                continue
            }

            if char == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }

            current.append(char)
        }

        if isEscaped {
            current.append("\\")
        }

        if !current.isEmpty || hadTrailingPipe {
            cells.append(current.trimmingCharacters(in: .whitespaces))
        }

        return cells
    }
}
