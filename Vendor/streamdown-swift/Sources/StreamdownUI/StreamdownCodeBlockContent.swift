import Combine
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct StreamdownCodeBlockContent: View {
    let language: String?
    let code: String
    var showLineNumbers: Bool
    var showHeader: Bool

    @Environment(\.streamdownTheme) private var theme
    @StateObject private var renderState: CodeBlockRenderState
    @State private var copied = false

    public init(
        language: String? = nil,
        code: String,
        showLineNumbers: Bool = false,
        showHeader: Bool = true
    ) {
        self.language = language
        self.code = code
        self.showLineNumbers = showLineNumbers
        self.showHeader = showHeader
        _renderState = StateObject(
            wrappedValue: CodeBlockRenderState(code: code, language: language)
        )
    }

    private var lineNumberWidth: CGFloat {
        let lineCount = max(1, renderState.displayedLineUpperBound)
        let digitCount = CGFloat(max(2, String(lineCount).count))
        return digitCount * 7.5 + 10
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                header
                    .padding(.horizontal, theme.spacing.md)
                    .padding(.vertical, theme.spacing.xs)
                    .overlay(alignment: .bottom) {
                        Divider()
                    }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if showLineNumbers {
                        numberedCode
                    } else {
                        nonNumberedCode
                    }
                }
            }
        }
        .background(theme.colors.tertiaryBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.colors.separator.opacity(0.45), lineWidth: 1)
        )
        .onReceive(Just(code)) { currentCode in
            renderState.update(code: currentCode, language: language)
        }
        .onReceive(Just(language)) { currentLanguage in
            renderState.update(code: code, language: currentLanguage)
        }
        .onAppear {
            renderState.updateAppearance(
                foreground: theme.colors.foreground,
                secondaryLabel: theme.colors.secondaryLabel
            )
        }
    }

    private var header: some View {
        HStack(spacing: theme.spacing.sm) {
            HStack(spacing: theme.spacing.sm) {
                if let language, !language.isEmpty {
                    Text(language.lowercased())
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundStyle(theme.colors.secondaryLabel)
                        .textCase(.lowercase)
                        .lineLimit(1)
                }
            }

            Spacer()
            Button {
                copyToClipboard(renderState.normalizedCode)
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var contentFont: Font {
        .system(size: 11, weight: .regular, design: .monospaced)
    }

    private var lineNumberFont: Font {
        .system(size: 11, weight: .medium, design: .monospaced)
    }

    private var nonNumberedCode: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(renderState.highlightedLines.indices, id: \.self) { index in
                Text(renderState.highlightedLines[index])
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 1)
                    .font(contentFont)
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, theme.spacing.md)
        .padding(.vertical, theme.spacing.xs)
    }

    private var numberedCode: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(renderState.lineTexts.enumerated()), id: \.offset) { index, _ in
                HStack(alignment: .firstTextBaseline, spacing: theme.spacing.sm) {
                    Text("\(renderState.displayedLineStart + index + 1)")
                        .font(lineNumberFont.monospacedDigit())
                        .foregroundStyle(theme.colors.tertiaryLabel)
                        .lineLimit(1)
                        .frame(width: lineNumberWidth, alignment: .trailing)
                        .padding(.leading, 2)

                    Text(renderState.highlightedLines[index])
                        .font(contentFont)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 1)
                }
                .padding(.leading, 1)
                .padding(.trailing, 1)
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, theme.spacing.md)
        .padding(.vertical, theme.spacing.xs)
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
