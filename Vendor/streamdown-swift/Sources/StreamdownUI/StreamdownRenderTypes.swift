import Foundation
import Streamdown
import SwiftUI

struct StreamdownInlineContent: Sendable {
    let attributed: AttributedString

    var characters: AttributedString.CharacterView {
        attributed.characters
    }
}

struct StreamdownMarkdownRenderBlock: Identifiable, Sendable {
    let id: String
    let source: String
}

struct StreamdownCodeRenderBlock: Identifiable, Sendable {
    let id: String
    let language: String?
    let code: String
    let startLine: Int?
    let isIncomplete: Bool
}

struct StreamdownTableRenderBlock: Identifiable, Sendable {
    let id: String
    let headers: [String]
    let rows: [[String]]
    let isIncomplete: Bool
    let headerInline: [StreamdownInlineContent?]
    let rowInline: [[StreamdownInlineContent?]]
    let columnWeights: [CGFloat]
}

enum StreamdownRenderedBlock: Identifiable, Sendable {
    case markdown(StreamdownMarkdownRenderBlock)
    case code(StreamdownCodeRenderBlock)
    case table(StreamdownTableRenderBlock)

    var id: String {
        switch self {
        case let .markdown(block):
            block.id
        case let .code(block):
            block.id
        case let .table(block):
            block.id
        }
    }
}

struct StreamdownRenderSnapshot: Sendable {
    let normalizedContent: String
    let parsedBlocks: [StreamdownParsedBlock]
    let blocks: [StreamdownRenderedBlock]
    let reusedBlockCount: Int
    let reusedRenderedBlockCount: Int

    static let empty = StreamdownRenderSnapshot(
        normalizedContent: "",
        parsedBlocks: [],
        blocks: [],
        reusedBlockCount: 0,
        reusedRenderedBlockCount: 0
    )
}

extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
