import Foundation

public enum StreamdownBlock: Equatable, Identifiable, Sendable {
    case markdown(String)
    case code(
        language: String?,
        code: String,
        startLine: Int?,
        isIncomplete: Bool
    )
    case table(
        headers: [String],
        rows: [[String]],
        isIncomplete: Bool
    )

    public var id: String {
        switch self {
        case let .markdown(content):
            "markdown-\(content.hashValue)"
        case let .code(language, code, startLine, _):
            "code-\(language ?? "")-\(startLine ?? 0)-\(code.hashValue)"
        case let .table(headers, rows, _):
            "table-\(headers.joined())-\(rows.count)"
        }
    }
}
