import Streamdown
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct StreamdownTableFullscreen: View {
    let headers: [String]
    let rows: [[String]]
    let controls: StreamdownControls.Table

    @Environment(\.dismiss) private var dismiss
    @Environment(\.streamdownTheme) private var theme

    var body: some View {
        VStack(spacing: theme.spacing.sm) {
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.plain)
            }
            .padding(theme.spacing.sm)

            ScrollView([.horizontal, .vertical]) {
                if controls.copy || controls.download {
                    HStack(alignment: .center, spacing: theme.spacing.sm) {
                        Spacer()

                        if controls.copy {
                            Menu {
                                Button("Copy Markdown") { copyTable(format: .markdown) }
                                Button("Copy CSV") { copyTable(format: .csv) }
                                Button("Copy TSV") { copyTable(format: .tsv) }
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .frame(
                                        width: theme.spacing.minTouchTarget,
                                        height: theme.spacing.minTouchTarget
                                    )
                            }
                        }

                        if controls.download {
                            Menu {
                                Button("Download CSV") { downloadTable(format: .csv) }
                                Button("Download Markdown") { downloadTable(format: .markdown) }
                            } label: {
                                Image(systemName: "arrow.down.circle")
                                    .frame(
                                        width: theme.spacing.minTouchTarget,
                                        height: theme.spacing.minTouchTarget
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, theme.spacing.sm)
                }

                StreamdownTableView(
                    headers: headers,
                    rows: rows,
                    controls: .init(
                        enabled: true,
                        copy: false,
                        download: false,
                        fullscreen: false
                    ),
                    isStreaming: false,
                    isIncomplete: false
                )
                .padding()
            }
        }
        .background(theme.colors.background)
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
