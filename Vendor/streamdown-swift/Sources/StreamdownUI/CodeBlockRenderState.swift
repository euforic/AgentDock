import Combine
import SwiftUI

@MainActor
final class CodeBlockRenderState: ObservableObject {
    private struct DisplayWindow: Sendable {
        let displayedLineStart: Int
        let lineTexts: [String]
        let highlightedLines: [AttributedString]
    }

    private struct RenderResult: Sendable {
        let normalizedCode: String
        let normalizedLanguage: String
        let displayWindow: DisplayWindow
    }

    @Published private(set) var normalizedCode: String
    @Published private(set) var displayedLineStart: Int
    @Published private(set) var lineTexts: [String]
    @Published private(set) var highlightedLines: [AttributedString]
    @Published private(set) var renderVersion = 1

    var displayedLineUpperBound: Int {
        displayedLineStart + lineTexts.count
    }

    private var normalizedLanguage: String
    private var renderTask: Task<Void, Never>?
    private var pendingGeneration = 0
    private let maxDisplayedLines: Int
    private var foreground: Color
    private var secondaryLabel: Color

    convenience init(foreground: Color = Color(white: 0.93), secondaryLabel: Color = Color(white: 0.55)) {
        self.init(code: "", language: nil, foreground: foreground, secondaryLabel: secondaryLabel)
    }

    init(
        code: String,
        language: String?,
        maxDisplayedLines: Int = 400,
        foreground: Color = Color(white: 0.93),
        secondaryLabel: Color = Color(white: 0.55)
    ) {
        self.maxDisplayedLines = max(1, maxDisplayedLines)
        self.foreground = foreground
        self.secondaryLabel = secondaryLabel
        let renderResult = Self.renderResult(
            code: code,
            language: language,
            maxDisplayedLines: self.maxDisplayedLines,
            foreground: foreground,
            secondaryLabel: secondaryLabel
        )
        self.normalizedCode = renderResult.normalizedCode
        self.normalizedLanguage = renderResult.normalizedLanguage
        self.displayedLineStart = renderResult.displayWindow.displayedLineStart
        self.lineTexts = renderResult.displayWindow.lineTexts
        self.highlightedLines = renderResult.displayWindow.highlightedLines
    }

    func update(code: String, language: String?) {
        let normalizedCode = Self.normalize(code)
        let normalizedLanguage = Self.normalize(language)

        guard normalizedCode != self.normalizedCode || normalizedLanguage != self.normalizedLanguage else {
            return
        }

        self.normalizedCode = normalizedCode
        self.normalizedLanguage = normalizedLanguage
        pendingGeneration &+= 1
        let generation = pendingGeneration
        let maxDisplayedLines = self.maxDisplayedLines
        let foreground = self.foreground
        let secondaryLabel = self.secondaryLabel
        renderTask?.cancel()
        renderTask = Task { [normalizedCode, normalizedLanguage] in
            let renderResult = await Task.detached(priority: .userInitiated) {
                Self.renderResult(
                    normalizedCode: normalizedCode,
                    normalizedLanguage: normalizedLanguage,
                    maxDisplayedLines: maxDisplayedLines,
                    foreground: foreground,
                    secondaryLabel: secondaryLabel
                )
            }.value
            guard !Task.isCancelled else { return }
            self.apply(renderResult, generation: generation)
        }
    }

    func updateAppearance(foreground: Color, secondaryLabel: Color) {
        guard foreground != self.foreground || secondaryLabel != self.secondaryLabel else {
            return
        }

        self.foreground = foreground
        self.secondaryLabel = secondaryLabel
        scheduleRender()
    }

    private func scheduleRender() {
        pendingGeneration &+= 1
        let generation = pendingGeneration
        let normalizedCode = self.normalizedCode
        let normalizedLanguage = self.normalizedLanguage
        let maxDisplayedLines = self.maxDisplayedLines
        let foreground = self.foreground
        let secondaryLabel = self.secondaryLabel
        renderTask?.cancel()
        renderTask = Task { [normalizedCode, normalizedLanguage] in
            let renderResult = await Task.detached(priority: .userInitiated) {
                Self.renderResult(
                    normalizedCode: normalizedCode,
                    normalizedLanguage: normalizedLanguage,
                    maxDisplayedLines: maxDisplayedLines,
                    foreground: foreground,
                    secondaryLabel: secondaryLabel
                )
            }.value
            guard !Task.isCancelled else { return }
            self.apply(renderResult, generation: generation)
        }
    }

    nonisolated private static func normalize(_ code: String) -> String {
        code
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
    }

    nonisolated private static func normalize(_ language: String?) -> String {
        language?.lowercased() ?? ""
    }

    nonisolated private static func lineTexts(from code: String) -> [String] {
        code.components(separatedBy: "\n")
    }

    nonisolated private static func highlightedLines(
        from lineTexts: [String],
        language: String,
        foreground: Color,
        secondaryLabel: Color
    ) -> [AttributedString] {
        lineTexts.map { line in
            let tokens = CodeBlockSyntaxHighlighter.tokens(
                for: line,
                language: language,
                foreground: foreground,
                secondaryLabel: secondaryLabel
            )
            var attributed = AttributedString()
            for token in tokens {
                var fragment = AttributedString(token.text)
                fragment.foregroundColor = token.color
                fragment.inlinePresentationIntent = token.isKeyword ? .stronglyEmphasized : nil
                attributed += fragment
            }
            return attributed
        }
    }

    nonisolated private static func renderResult(
        code: String,
        language: String?,
        maxDisplayedLines: Int,
        foreground: Color,
        secondaryLabel: Color
    ) -> RenderResult {
        renderResult(
            normalizedCode: normalize(code),
            normalizedLanguage: normalize(language),
            maxDisplayedLines: maxDisplayedLines,
            foreground: foreground,
            secondaryLabel: secondaryLabel
        )
    }

    nonisolated private static func renderResult(
        normalizedCode: String,
        normalizedLanguage: String,
        maxDisplayedLines: Int,
        foreground: Color,
        secondaryLabel: Color
    ) -> RenderResult {
        let allLineTexts = lineTexts(from: normalizedCode)
        let displayWindow = trimmedDisplayWindow(
            lineTexts: allLineTexts,
            language: normalizedLanguage,
            maxDisplayedLines: maxDisplayedLines,
            foreground: foreground,
            secondaryLabel: secondaryLabel
        )
        return RenderResult(
            normalizedCode: normalizedCode,
            normalizedLanguage: normalizedLanguage,
            displayWindow: displayWindow
        )
    }

    nonisolated private static func trimmedDisplayWindow(
        lineTexts: [String],
        language: String,
        maxDisplayedLines: Int,
        foreground: Color,
        secondaryLabel: Color
    ) -> DisplayWindow {
        guard lineTexts.count > maxDisplayedLines else {
            return DisplayWindow(
                displayedLineStart: 0,
                lineTexts: lineTexts,
                highlightedLines: highlightedLines(
                    from: lineTexts,
                    language: language,
                    foreground: foreground,
                    secondaryLabel: secondaryLabel
                )
            )
        }

        let displayedLineStart = lineTexts.count - maxDisplayedLines
        let displayedLineTexts = Array(lineTexts.suffix(maxDisplayedLines))
        return DisplayWindow(
            displayedLineStart: displayedLineStart,
            lineTexts: displayedLineTexts,
            highlightedLines: highlightedLines(
                from: displayedLineTexts,
                language: language,
                foreground: foreground,
                secondaryLabel: secondaryLabel
            )
        )
    }

    private func apply(_ renderResult: RenderResult, generation: Int) {
        guard generation == pendingGeneration else { return }
        displayedLineStart = renderResult.displayWindow.displayedLineStart
        lineTexts = renderResult.displayWindow.lineTexts
        highlightedLines = renderResult.displayWindow.highlightedLines
        renderVersion &+= 1
    }
}
