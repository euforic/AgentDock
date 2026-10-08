import SwiftUI

struct StreamdownTableCell: View {
    let text: String
    let inlineContent: StreamdownInlineContent?
    let isHeader: Bool
    let color: Color

    @Environment(\.streamdownTheme) private var theme

    static let rowMinHeight: CGFloat = 36

    private var cellVerticalPadding: CGFloat {
        theme.spacing.sm + theme.spacing.xxs
    }

    var body: some View {
        if let inlineContent {
            Text(inlineContent.attributed)
                .font(isHeader ? theme.fonts.subheadline.weight(.semibold) : nil)
                .foregroundStyle(color)
                .padding(.horizontal, theme.spacing.sm)
                .padding(.vertical, cellVerticalPadding)
                .lineLimit(nil)
                .frame(
                    maxWidth: .infinity,
                    minHeight: Self.rowMinHeight,
                    alignment: .topLeading
                )
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(isHeader ? theme.fonts.subheadline.weight(.semibold) : theme.fonts.body)
                .foregroundStyle(color)
                .padding(.horizontal, theme.spacing.sm)
                .padding(.vertical, cellVerticalPadding)
                .frame(
                    maxWidth: .infinity,
                    minHeight: Self.rowMinHeight,
                    alignment: .topLeading
                )
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
