extension StreamdownParser {
    static func isMathBlockUnclosed(_ markdown: String) -> Bool {
        var hasUnclosedMathBlock = false
        updateMathBlockState(
            with: markdown,
            hasUnclosedMathBlock: &hasUnclosedMathBlock
        )
        return hasUnclosedMathBlock
    }

    static func updateMathBlockState(
        with text: String,
        hasUnclosedMathBlock: inout Bool
    ) {
        var count = 0
        var index = text.startIndex
        var isEscaped = false

        while index < text.endIndex {
            let character = text[index]
            if character == "\\" && !isEscaped {
                isEscaped = true
                index = text.index(after: index)
                continue
            }

            if !isEscaped && character == "$", text.distance(from: index, to: text.endIndex) > 1 {
                let next = text.index(after: index)
                if text[next] == "$" {
                    count += 1
                    index = text.index(after: next)
                    continue
                }
            }

            isEscaped = false
            index = text.index(after: index)
        }

        if count.isMultiple(of: 2) {
            return
        }

        hasUnclosedMathBlock.toggle()
    }
}
