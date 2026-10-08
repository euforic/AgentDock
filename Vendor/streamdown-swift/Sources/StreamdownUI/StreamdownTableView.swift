import Streamdown
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private enum StreamdownTableStyle {
    static let cornerRadius: CGFloat = 10
    static let controlIconSize: CGFloat = 12
    static let gridLineWidth: CGFloat = 1
}

struct StreamdownTableView: View {
    let headers: [String]
    let rows: [[String]]
    let headerInline: [StreamdownInlineContent?]
    let rowInline: [[StreamdownInlineContent?]]
    let columnWeights: [CGFloat]
    let controls: StreamdownControls.Table
    let isStreaming: Bool
    let isIncomplete: Bool

    @Environment(\.streamdownTheme) private var theme
    @State private var isFullscreen = false
    private let showCopy: Bool
    private let showDownload: Bool
    private let showFullscreen: Bool

    private var columnCount: Int {
        max(headers.count, rows.reduce(0) { max($0, $1.count) })
    }

    private func header(at index: Int) -> String {
        if headers.indices.contains(index) {
            return headers[index]
        }
        return ""
    }

    private func cellValue(in row: [String], at index: Int) -> String {
        guard row.indices.contains(index) else { return "" }
        return row[index]
    }

    init(
        headers: [String],
        rows: [[String]],
        headerInline: [StreamdownInlineContent?] = [],
        rowInline: [[StreamdownInlineContent?]] = [],
        columnWeights: [CGFloat] = [],
        controls: StreamdownControls.Table,
        isStreaming: Bool,
        isIncomplete: Bool
    ) {
        self.headers = headers
        self.rows = rows
        self.headerInline = headerInline
        self.rowInline = rowInline
        self.columnWeights = columnWeights
        self.controls = controls
        self.isStreaming = isStreaming
        self.isIncomplete = isIncomplete
        self.showCopy = controls.enabled && controls.copy
        self.showDownload = controls.enabled && controls.download
        self.showFullscreen = controls.enabled && controls.fullscreen
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: theme.spacing.sm) {
                if showCopy || showDownload || showFullscreen {
                    HStack(alignment: .center, spacing: theme.spacing.sm) {
                        Spacer()

                        if showCopy {
                            Menu {
                                Button("Copy Markdown") { copyTable(format: .markdown) }
                                Button("Copy CSV") { copyTable(format: .csv) }
                                Button("Copy TSV") { copyTable(format: .tsv) }
                            } label: {
                                controlIcon(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .disabled(isStreaming)
                        }

                        if showDownload {
                            Menu {
                                Button("Download CSV") { downloadTable(format: .csv) }
                                Button("Download Markdown") { downloadTable(format: .markdown) }
                            } label: {
                                controlIcon(systemName: "arrow.down.circle")
                            }
                            .buttonStyle(.plain)
                            .disabled(isStreaming)
                        }

                        if showFullscreen {
                            Button {
                                isFullscreen = true
                            } label: {
                                controlIcon(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .buttonStyle(.plain)
                            .disabled(isStreaming)
                        }
                    }
                }

                tableContent
                    .overlay(alignment: .center) {
                        if isIncomplete {
                            HStack(spacing: theme.spacing.xs) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Streaming table...")
                                    .font(theme.fonts.caption2)
                                    .foregroundStyle(theme.colors.mutedForeground)
                            }
                            .padding(theme.spacing.md)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(theme.colors.background.opacity(0.15))
                        }
                    }
                    #if os(macOS)
                    .sheet(isPresented: $isFullscreen) {
                        StreamdownTableFullscreen(
                            headers: headers,
                            rows: rows,
                            controls: controls
                        )
                    }
                    #else
                    .fullScreenCover(isPresented: $isFullscreen) {
                        StreamdownTableFullscreen(
                            headers: headers,
                            rows: rows,
                            controls: controls
                        )
                    }
                    #endif
            }

            Color.clear
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("streamdown-table-root")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
        }
        .padding(theme.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: StreamdownTableStyle.cornerRadius)
                .fill(theme.colors.secondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: StreamdownTableStyle.cornerRadius)
                        .stroke(theme.colors.border, lineWidth: 1)
                )
        )
    }

    private var tableContent: some View {
        let safeColumnCount = max(columnCount, 1)
        let columnWidths = resolvedColumnWidths(
            containerWidth: fallbackTableWidth,
            columnCount: safeColumnCount
        )
        let tableWidth = columnWidths.reduce(0, +)
            + (CGFloat(max(0, safeColumnCount - 1)) * StreamdownTableStyle.gridLineWidth)

        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                if !headers.isEmpty {
                    tableRow(
                        label: "header",
                        isHeader: true,
                        values: headers,
                        inlineValues: headerInline,
                        columnWidths: columnWidths
                    )

                    if !rows.isEmpty {
                        horizontalGridSeparator
                    }
                }

                ForEach(rows.indices, id: \.self) { rowIndex in
                    let row = rows[rowIndex]

                    tableRow(
                        label: "\(rowIndex)",
                        isHeader: false,
                        values: row,
                        inlineValues: rowInlineValue(at: rowIndex),
                        columnWidths: columnWidths,
                        isAlternatingRow: rowIndex % 2 == 1
                    )

                    if rowIndex < rows.count - 1 {
                        horizontalGridSeparator
                    }
                }
            }
            .frame(width: tableWidth, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.colors.border, lineWidth: 1)
            )
        }
        .accessibilityElement(children: .contain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("streamdown-table-scroll-view")
    }

    @ViewBuilder
    private func tableRow(
        label: String,
        isHeader: Bool,
        values: [String],
        inlineValues: [StreamdownInlineContent?],
        columnWidths: [CGFloat],
        isAlternatingRow: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { index in
                let value = isHeader ? header(at: index) : cellValue(in: values, at: index)
                HStack(spacing: 0) {
                    tableCell(
                        text: value,
                        inlineContent: inlineValue(in: inlineValues, at: index),
                        isHeader: isHeader,
                        rowLabel: label,
                        columnIndex: index,
                        columnWidth: columnWidth(at: index, columnWidths: columnWidths)
                    )

                    if index < columnCount - 1 {
                        verticalGridSeparator
                    }
                }
            }
        }
        .frame(
            width: columnWidths.reduce(0, +)
                + (CGFloat(max(0, columnCount - 1)) * StreamdownTableStyle.gridLineWidth),
            alignment: .leading
        )
        .accessibilityIdentifier(isHeader ? "streamdown-table-header-row" : "streamdown-table-row-\(label)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isHeader ? "streamdown table header row" : "streamdown table row \(label)")
        .background(
            isHeader
                ? theme.colors.tertiaryBackground
                : (isAlternatingRow ? theme.colors.tertiaryBackground.opacity(0.25) : Color.clear)
        )
    }

    @ViewBuilder
    private func tableCell(
        text: String,
        inlineContent: StreamdownInlineContent?,
        isHeader: Bool,
        rowLabel: String,
        columnIndex: Int,
        columnWidth: CGFloat
    ) -> some View {
        StreamdownTableCell(
            text: text,
            inlineContent: inlineContent,
            isHeader: isHeader,
            color: theme.colors.foreground
        )
        .frame(width: columnWidth, alignment: .leading)
        .accessibilityIdentifier("streamdown-table-cell-\(rowLabel)-col-\(columnIndex)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("table-\(rowLabel)-col-\(columnIndex)")
        .fixedSize(horizontal: false, vertical: true)
    }

    private func copyTable(format: TableExportFormat) {
        guard let text = formattedTable(format: format) else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private func downloadTable(format: TableExportFormat) {
        guard let text = formattedTable(format: format) else { return }
        let filename = format == .csv ? "table.csv" : "table.md"
        shareFile(text, filename: filename)
    }

    private func formattedTable(format: TableExportFormat) -> String? {
        let data = StreamdownTableData(headers: headers, rows: rows)
        switch format {
        case .csv:
            return data.toCSV()
        case .tsv:
            return data.toTSV()
        case .markdown:
            return data.toMarkdownTable()
        }
    }

    private func controlIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: StreamdownTableStyle.controlIconSize, weight: .medium))
            .foregroundStyle(theme.colors.secondaryLabel)
            .padding(theme.spacing.xxs / 2)
            .contentShape(Rectangle())
    }

    private var horizontalGridSeparator: some View {
        Rectangle()
            .fill(theme.colors.border)
            .frame(height: StreamdownTableStyle.gridLineWidth)
    }

    private var verticalGridSeparator: some View {
        Rectangle()
            .fill(theme.colors.border)
            .frame(width: StreamdownTableStyle.gridLineWidth)
    }

    private func shareFile(_ text: String, filename: String) {
        #if canImport(UIKit)
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let file = tempDir.appendingPathComponent(filename)
        try? text.write(to: file, atomically: true, encoding: .utf8)
        let activity = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        let presenter = root.presentedViewController ?? root
        activity.popoverPresentationController?.sourceView = presenter.view
        presenter.present(activity, animated: true)
        #endif
    }
}

extension StreamdownTableView {
    func rowInlineValue(at index: Int) -> [StreamdownInlineContent?] {
        guard rowInline.indices.contains(index) else { return [] }
        return rowInline[index]
    }

    func inlineValue(in values: [StreamdownInlineContent?], at index: Int) -> StreamdownInlineContent? {
        guard values.indices.contains(index) else { return nil }
        return values[index]
    }

    var fallbackTableWidth: CGFloat {
        #if canImport(UIKit)
        let widestScreen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen.bounds.width }
            .max() ?? 720
        return max(widestScreen - (theme.spacing.md * 2), theme.spacing.base * 10)
        #elseif canImport(AppKit)
        return 720
        #else
        return theme.spacing.base * 10
        #endif
    }

    func columnWidth(at index: Int, columnWidths: [CGFloat]) -> CGFloat {
        if columnWidths.indices.contains(index) {
            return columnWidths[index]
        }
        return theme.spacing.base * 10
    }

    func resolvedColumnWidths(containerWidth: CGFloat, columnCount: Int) -> [CGFloat] {
        guard columnCount > 0 else { return [] }

        let minWidth = theme.spacing.base * 10
        let weighted = (0..<columnCount).map { index in
            if columnWeights.indices.contains(index) {
                return columnWeights[index]
            }
            return CGFloat(1)
        }
        let totalWeight = max(weighted.reduce(0, +), .leastNonzeroMagnitude)

        var widths = weighted.map { weight in
            max((containerWidth * weight) / totalWeight, minWidth)
        }

        let minimumTotal = minWidth * CGFloat(columnCount)
        let targetTotal = max(containerWidth, minimumTotal)
        let currentTotal = widths.reduce(0, +)

        if currentTotal < targetTotal {
            let extra = targetTotal - currentTotal
            widths = zip(widths, weighted).map { width, weight in
                width + ((extra * weight) / totalWeight)
            }
        }

        return widths
    }
}
