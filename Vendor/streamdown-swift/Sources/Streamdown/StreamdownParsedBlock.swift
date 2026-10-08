public struct StreamdownParsedBlock: Sendable {
    public let block: StreamdownBlock
    public let range: Range<Int>

    public init(block: StreamdownBlock, range: Range<Int>) {
        self.block = block
        self.range = range
    }

    public func offsetting(by offset: Int) -> StreamdownParsedBlock {
        StreamdownParsedBlock(
            block: block,
            range: (range.lowerBound + offset)..<(range.upperBound + offset)
        )
    }
}
