import Foundation

public struct StreamdownTableData: Sendable {
    public let headers: [String]
    public let rows: [[String]]

    public init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows
    }

    public func toCSV(excelCompatible: Bool = false) -> String {
        let escapeCSV: (String) -> String = { value in
            let needsEscaping = value.contains("\"") || value.contains(",") || value.contains("\n")
            if !needsEscaping { return value }
            if value.contains("\"") {
                return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return "\"\(value)\""
        }

        var output: [String] = []
        if !headers.isEmpty {
            output.append(headers.map(escapeCSV).joined(separator: ","))
        }
        for row in rows {
            output.append(row.map(escapeCSV).joined(separator: ","))
        }
        let csv = output.joined(separator: "\n")
        if excelCompatible {
            return "\u{FEFF}" + csv
        }
        return csv
    }

    public func toTSV() -> String {
        let escapeTSV: (String) -> String = { value in
            if value.contains("\t") || value.contains("\n") || value.contains("\r") {
                return value
                    .replacingOccurrences(of: "\t", with: "\\t")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "\\r")
            }
            return value
        }

        var output: [String] = []
        if !headers.isEmpty {
            output.append(headers.map(escapeTSV).joined(separator: "\t"))
        }
        for row in rows {
            output.append(row.map(escapeTSV).joined(separator: "\t"))
        }
        return output.joined(separator: "\n")
    }

    public func toMarkdownTable() -> String {
        guard !headers.isEmpty else { return "" }

        let columnCount = max(
            headers.count,
            rows.reduce(0) { max($0, $1.count) }
        )

        var out: [String] = []
        let paddedHeaders = headers + Array(repeating: "", count: max(0, columnCount - headers.count))
        let escapedHeaders = paddedHeaders.map { escapeMarkdownTableCell($0) }
        let separator = Array(repeating: "---", count: columnCount).joined(separator: " | ")

        out.append("| \(escapedHeaders.joined(separator: " | ")) |")
        out.append("| \(separator) |")

        for row in rows {
            let padded = row + Array(repeating: "", count: max(0, columnCount - row.count))
            let limited = padded.prefix(columnCount)
            let escaped = limited.map { cell in
                escapeMarkdownTableCell(cell)
            }

            out.append("| \(escaped.joined(separator: " | ")) |")
        }
        return out.joined(separator: "\n")
    }

    private func escapeMarkdownTableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
