import Testing
@testable import Streamdown

// MARK: - CSV export

@Test func csvExport() {
    let table = StreamdownTableData(
        headers: ["Name", "Age"],
        rows: [["Alice", "30"], ["Bob", "25"]]
    )
    let csv = table.toCSV()
    #expect(csv == "Name,Age\nAlice,30\nBob,25")
}

@Test func csvEscaping() {
    let table = StreamdownTableData(
        headers: ["Value"],
        rows: [
            ["has \"quotes\""],
            ["has,comma"],
            ["has\nnewline"],
        ]
    )
    let csv = table.toCSV()
    let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines[0] == "Value")
    #expect(lines[1] == "\"has \"\"quotes\"\"\"")
    #expect(String(lines[2]) == "\"has,comma\"")
    // The newline value will be inside quotes spanning two lines
    let remaining = lines[3...].joined(separator: "\n")
    #expect(remaining.contains("has"))
    #expect(remaining.contains("newline"))
}

@Test func csvExcelCompatible() {
    let table = StreamdownTableData(
        headers: ["Name", "Age"],
        rows: [["Alice", "30"]]
    )
    let csv = table.toCSV(excelCompatible: true)
    #expect(csv.hasPrefix("\u{FEFF}"))
    #expect(csv.dropFirst().hasPrefix("Name,Age"))

    let csvNormal = table.toCSV()
    #expect(!csvNormal.hasPrefix("\u{FEFF}"))
}

@Test func csvExcelCompatibleBOMBytes() {
    let table = StreamdownTableData(headers: ["A"], rows: [])
    let csv = table.toCSV(excelCompatible: true)
    let data = csv.data(using: .utf8)!
    // UTF-8 BOM is EF BB BF
    #expect(data[0] == 0xEF)
    #expect(data[1] == 0xBB)
    #expect(data[2] == 0xBF)
}

@Test func csvExcelCompatibleEmptyTable() {
    let table = StreamdownTableData(headers: [], rows: [])
    let csv = table.toCSV(excelCompatible: true)
    #expect(csv == "\u{FEFF}")

    let csvNormal = table.toCSV(excelCompatible: false)
    #expect(csvNormal == "")
}

@Test func csvSingleColumn() {
    let table = StreamdownTableData(
        headers: ["Name"],
        rows: [["Alice"], ["Bob"]]
    )
    let csv = table.toCSV()
    #expect(csv == "Name\nAlice\nBob")
}

@Test func csvValueWithAllSpecialChars() {
    // Value with quotes, commas, and newlines combined
    let table = StreamdownTableData(
        headers: ["H"],
        rows: [["He said \"hello,\nworld\""]]
    )
    let csv = table.toCSV()
    #expect(csv.contains("\"\""))
}

@Test func csvUnicodeContent() {
    let table = StreamdownTableData(
        headers: ["Emoji", "Description"],
        rows: [["🍎", "Apple"], ["日本語", "Japanese"]]
    )
    let csv = table.toCSV()
    #expect(csv.contains("🍎"))
    #expect(csv.contains("日本語"))
}

@Test func csvLargeTable() {
    let headers = (0..<10).map { "Col\($0)" }
    let rows = (0..<100).map { row in
        (0..<10).map { col in "R\(row)C\(col)" }
    }
    let table = StreamdownTableData(headers: headers, rows: rows)
    let csv = table.toCSV()
    let lines = csv.components(separatedBy: "\n")
    #expect(lines.count == 101) // 1 header + 100 data rows
}

// MARK: - TSV export

@Test func tsvExport() {
    let table = StreamdownTableData(
        headers: ["Name", "Age"],
        rows: [["Alice", "30"], ["Bob", "25"]]
    )
    let tsv = table.toTSV()
    #expect(tsv == "Name\tAge\nAlice\t30\nBob\t25")
}

@Test func tsvEscaping() {
    let table = StreamdownTableData(
        headers: ["Col"],
        rows: [
            ["has\ttab"],
            ["has\nnewline"],
        ]
    )
    let tsv = table.toTSV()
    let lines = tsv.split(separator: "\n")
    #expect(lines[0] == "Col")
    #expect(lines[1] == "has\\ttab")
    #expect(lines[2] == "has\\nnewline")
}

@Test func tsvCarriageReturnEscaping() {
    let table = StreamdownTableData(
        headers: ["Col"],
        rows: [["has\rCR"]]
    )
    let tsv = table.toTSV()
    #expect(tsv.contains("has\\rCR"))
}

@Test func tsvUnicodeContent() {
    let table = StreamdownTableData(
        headers: ["Name"],
        rows: [["café"], ["naïve"]]
    )
    let tsv = table.toTSV()
    #expect(tsv.contains("café"))
    #expect(tsv.contains("naïve"))
}

// MARK: - Markdown table export

@Test func markdownTableExport() {
    let table = StreamdownTableData(
        headers: ["Name", "Age"],
        rows: [["Alice", "30"], ["Bob", "25"]]
    )
    let md = table.toMarkdownTable()
    let expected = """
    | Name | Age |
    | --- | --- |
    | Alice | 30 |
    | Bob | 25 |
    """
    #expect(md == expected)
}

@Test func markdownTableEmptyHeaders() {
    let table = StreamdownTableData(headers: [], rows: [["a", "b"]])
    let md = table.toMarkdownTable()
    #expect(md == "")
}

@Test func markdownTablePipeEscaping() {
    let table = StreamdownTableData(
        headers: ["Code", "Output"],
        rows: [["a | b", "result"]]
    )
    let md = table.toMarkdownTable()
    #expect(md.contains("a \\| b"))
    #expect(md.contains("result"))
}

@Test func markdownTableBackslashEscaping() {
    let table = StreamdownTableData(
        headers: ["Path"],
        rows: [["C:\\Users\\test"]]
    )
    let md = table.toMarkdownTable()
    #expect(md.contains("C:\\\\Users\\\\test"))
}

@Test func markdownTableNewlineInCell() {
    let table = StreamdownTableData(
        headers: ["Text"],
        rows: [["line1\nline2"]]
    )
    let md = table.toMarkdownTable()
    #expect(md.contains("line1<br>line2"))
}

@Test func markdownTableRaggedRows() {
    // Rows with more columns than headers should be limited
    let table = StreamdownTableData(
        headers: ["A", "B"],
        rows: [["1", "2", "3"]]
    )
    let md = table.toMarkdownTable()
    let dataRow = md.components(separatedBy: "\n").last!
    let cells = dataRow.components(separatedBy: "|").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    #expect(cells.count == 3) // column count = max(headers, row)
}

@Test func markdownTableFewerColumnsThanHeaders() {
    let table = StreamdownTableData(
        headers: ["A", "B", "C"],
        rows: [["1"]]
    )
    let md = table.toMarkdownTable()
    // Row should be padded with empty cells to match 3 columns
    let lines = md.components(separatedBy: "\n")
    #expect(lines.count == 3) // header, separator, 1 data row
    let dataRow = lines[2]
    // Should contain 3 pipe-separated cells: "| 1 |  |  |"
    #expect(dataRow.hasPrefix("| "))
    #expect(dataRow.hasSuffix(" |"))
    // Re-parse to verify it round-trips
    let blocks = StreamdownParser.parseBlocks(content: md, mode: .static)
    if case let .table(headers, rows, _) = blocks.first {
        #expect(headers == ["A", "B", "C"])
        #expect(rows.count == 1)
        #expect(rows[0].count == 3)
        #expect(rows[0][0] == "1")
    }
}

// MARK: - Empty/edge cases

@Test func emptyRows() {
    let table = StreamdownTableData(
        headers: ["A", "B"],
        rows: []
    )
    let csv = table.toCSV()
    #expect(csv == "A,B")

    let tsv = table.toTSV()
    #expect(tsv == "A\tB")

    let md = table.toMarkdownTable()
    #expect(md.contains("| A | B |"))
    #expect(md.contains("| --- | --- |"))
}

@Test func emptyHeaders() {
    let table = StreamdownTableData(headers: [], rows: [])
    #expect(table.toCSV() == "")
    #expect(table.toTSV() == "")
    #expect(table.toMarkdownTable() == "")
}

@Test func singleCellTable() {
    let table = StreamdownTableData(
        headers: ["Only"],
        rows: [["value"]]
    )
    let csv = table.toCSV()
    #expect(csv == "Only\nvalue")

    let md = table.toMarkdownTable()
    #expect(md.contains("| Only |"))
    #expect(md.contains("| value |"))
}

@Test func emptyCellValues() {
    let table = StreamdownTableData(
        headers: ["A", "B"],
        rows: [["", ""], ["x", ""]]
    )
    let csv = table.toCSV()
    #expect(csv == "A,B\n,\nx,")

    let tsv = table.toTSV()
    #expect(tsv == "A\tB\n\t\nx\t")
}

// MARK: - Round-trip consistency

@Test func markdownExportRoundTrip() {
    // Export to markdown, then re-parse
    let table = StreamdownTableData(
        headers: ["Name", "Score"],
        rows: [["Alice", "95"], ["Bob", "87"]]
    )
    let md = table.toMarkdownTable()
    let blocks = StreamdownParser.parseBlocks(content: md, mode: .static)
    let tableBlocks = blocks.filter {
        if case .table = $0 { return true }
        return false
    }
    #expect(tableBlocks.count == 1)
    if case let .table(headers, rows, _) = tableBlocks.first {
        #expect(headers == ["Name", "Score"])
        #expect(rows == [["Alice", "95"], ["Bob", "87"]])
    }
}

@Test func markdownExportRoundTripWithSpecialChars() {
    let table = StreamdownTableData(
        headers: ["Key", "Value"],
        rows: [["a | b", "c \\ d"]]
    )
    let md = table.toMarkdownTable()
    let blocks = StreamdownParser.parseBlocks(content: md, mode: .static)
    let tableBlocks = blocks.filter {
        if case .table = $0 { return true }
        return false
    }
    #expect(tableBlocks.count == 1)
    if case let .table(_, rows, _) = tableBlocks.first {
        #expect(rows[0][0] == "a | b")
        #expect(rows[0][1] == "c \\ d")
    }
}
