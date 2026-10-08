extension StreamdownParser {
    static func parseCodeFenceStart(line: String) -> CodeFenceInfo? {
        let characters = Array(line)
        var start = 0

        while start < characters.count && start < 3 && (characters[start] == " " || characters[start] == "\t") {
            start += 1
        }

        guard start < characters.count else {
            return nil
        }

        let fenceCharacter = characters[start]
        guard fenceCharacter == "`" || fenceCharacter == "~" else {
            return nil
        }

        var fenceEnd = start + 1
        while fenceEnd < characters.count && characters[fenceEnd] == fenceCharacter {
            fenceEnd += 1
        }

        let fenceLength = fenceEnd - start
        guard fenceLength >= 3 else {
            return nil
        }

        let fence = String(repeating: String(fenceCharacter), count: fenceLength)
        let remainder = String(characters[fenceEnd...]).trimmingCharacters(in: .whitespaces)

        if remainder.isEmpty {
            return CodeFenceInfo(fence: fence, language: nil, startLine: nil)
        }

        let parts = remainder.split(whereSeparator: { $0 == " " || $0 == "\t" })
        var language: String?
        var startLine: Int?

        for part in parts {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.isEmpty {
                continue
            }

            if token.lowercased().hasPrefix("startline=") {
                startLine = Int(token.lowercased().dropFirst("startline=".count))
            } else if language == nil {
                language = token
            }
        }

        return CodeFenceInfo(fence: fence, language: language, startLine: startLine)
    }

    static func isCodeFenceEnd(_ line: String, fence: String) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard let first = fence.first else { return false }
        return !trimmedLine.isEmpty
            && trimmedLine.allSatisfy { $0 == first }
            && trimmedLine.count >= fence.count
    }
}
