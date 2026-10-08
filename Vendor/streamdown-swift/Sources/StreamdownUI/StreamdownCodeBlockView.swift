import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct StreamdownCodeBlockView: View {
    let language: String?
    let code: String
    let startLine: Int?
    let isIncomplete: Bool
    let controlsCopy: Bool
    let controlsDownload: Bool
    let isStreaming: Bool
    let showFullscreen: Bool
    let isMermaid: Bool
    let mermaidPanZoom: Bool
    var showLineNumbers: Bool = false

    @Environment(\.streamdownTheme) private var theme
    @State private var copied = false
    @State private var isFullscreen = false

    private let mermaidLanguages = Set(["mermaid", "flowchart", "graphviz"])

    private var normalizedLanguage: String? {
        language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var cornerRadius: CGFloat { 8 }
    private var headerIconSize: CGFloat { 12 }
    private var controlTapPadding: CGFloat { 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: theme.spacing.sm) {
                if let language {
                    Text(language)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.colors.secondaryLabel)
                        .textCase(.lowercase)
                        .lineLimit(1)
                }
                if let startLine {
                    Text("startLine \(startLine)")
                        .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(theme.colors.tertiaryLabel)
                        .lineLimit(1)
                }

                Spacer()

                if controlsCopy {
                    Button(action: copy) {
                        headerIcon(
                            systemName: copied ? "checkmark" : "doc.on.doc",
                            foregroundStyle: copied ? Color.green : theme.colors.secondaryLabel
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isStreaming)
                }

                if controlsDownload {
                    Menu {
                        Button("Download as \(defaultFilename)") { download() }
                    } label: {
                        headerIcon(systemName: "arrow.down.to.line")
                    }
                    .disabled(isStreaming)
                }

                if showFullscreen {
                    Button(action: { isFullscreen = true }) {
                        headerIcon(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    .disabled(isStreaming)
                }
            }
            .padding(.horizontal, theme.spacing.md)
            .padding(.vertical, 0)
            .overlay(alignment: .bottom) {
                Divider()
            }

            if isIncomplete && code.isEmpty {
                VStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Streaming block...")
                        .font(theme.fonts.caption)
                        .foregroundStyle(theme.colors.mutedForeground)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(theme.colors.secondaryBackground)
            } else {
                if shouldRenderMermaid {
                    StreamdownMermaidView(
                        source: code,
                        panZoom: mermaidPanZoom
                    )
                    .frame(minHeight: 120)
                } else {
                    StreamdownCodeBlockContent(
                        language: normalizedLanguage,
                        code: code,
                        showLineNumbers: showLineNumbers,
                        showHeader: false
                    )
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(theme.colors.tertiaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(theme.colors.separator.opacity(0.45), lineWidth: 1)
                )
        )
        .overlay(alignment: .bottomTrailing) {
            if shouldShowMermaidNote {
                Text("Mermaid rendering not available yet")
                    .font(.caption2)
                    .foregroundStyle(theme.colors.mutedForeground)
                    .padding(theme.spacing.xs)
            }
        }
        #if os(macOS)
        .sheet(isPresented: $isFullscreen) {
            StreamdownCodeFullscreen(language: normalizedLanguage, code: code)
        }
        #else
        .fullScreenCover(isPresented: $isFullscreen) {
            StreamdownCodeFullscreen(language: normalizedLanguage, code: code)
        }
        #endif
    }

    private var defaultFilename: String {
        "\(normalizedLanguage ?? "code").txt"
    }

    private var shouldShowMermaidNote: Bool {
        guard isMermaid else { return false }
        return !shouldRenderMermaid
    }

    private var shouldRenderMermaid: Bool {
        guard isMermaid else { return false }
        return mermaidLanguages.contains(normalizedLanguage ?? "") || normalizedLanguage == "mermaid"
    }

    private func headerIcon(
        systemName: String,
        foregroundStyle: some ShapeStyle = Color(white: 0.55)
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: headerIconSize, weight: .medium))
            .foregroundStyle(foregroundStyle)
            .padding(controlTapPadding)
            .contentShape(Rectangle())
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = code
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func download() {
        let filename = "\(normalizedLanguage ?? "code").txt"
        shareFile(code, filename: filename)
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

struct StreamdownCodeFullscreen: View {
    let language: String?
    let code: String

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

            StreamdownCodeBlockContent(
                language: language,
                code: code,
                showLineNumbers: false
            )
            .padding()
            Spacer()
        }
        .background(theme.colors.background)
    }
}
