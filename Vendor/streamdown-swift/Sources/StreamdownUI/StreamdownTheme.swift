import SwiftUI

public struct StreamdownTheme: Sendable {
    public var spacing: Spacing
    public var colors: Colors
    public var fonts: Fonts

    public struct Spacing: Sendable {
        public var xxs: CGFloat
        public var xs: CGFloat
        public var sm: CGFloat
        public var md: CGFloat
        public var base: CGFloat
        public var lg: CGFloat
        public var minTouchTarget: CGFloat

        public init(
            xxs: CGFloat = 2,
            xs: CGFloat = 4,
            sm: CGFloat = 8,
            md: CGFloat = 12,
            base: CGFloat = 16,
            lg: CGFloat = 24,
            minTouchTarget: CGFloat = 44
        ) {
            self.xxs = xxs
            self.xs = xs
            self.sm = sm
            self.md = md
            self.base = base
            self.lg = lg
            self.minTouchTarget = minTouchTarget
        }

        public static let `default` = Spacing()
    }

    public struct Colors: Sendable {
        public var background: Color
        public var foreground: Color
        public var secondaryBackground: Color
        public var tertiaryBackground: Color
        public var secondaryLabel: Color
        public var tertiaryLabel: Color
        public var mutedForeground: Color
        public var border: Color
        public var separator: Color
        public var card: Color

        public init(
            background: Color = Color(white: 0.08),
            foreground: Color = Color(white: 0.93),
            secondaryBackground: Color = Color(white: 0.10),
            tertiaryBackground: Color = Color(white: 0.14),
            secondaryLabel: Color = Color(white: 0.55),
            tertiaryLabel: Color = Color(white: 0.40),
            mutedForeground: Color = Color(white: 0.55),
            border: Color = Color(white: 0.16),
            separator: Color = Color(white: 0.16),
            card: Color = Color(white: 0.10)
        ) {
            self.background = background
            self.foreground = foreground
            self.secondaryBackground = secondaryBackground
            self.tertiaryBackground = tertiaryBackground
            self.secondaryLabel = secondaryLabel
            self.tertiaryLabel = tertiaryLabel
            self.mutedForeground = mutedForeground
            self.border = border
            self.separator = separator
            self.card = card
        }

        public static let `default` = Colors()
    }

    public struct Fonts: Sendable {
        public var body: Font
        public var caption: Font
        public var caption2: Font
        public var callout: Font
        public var subheadline: Font
        public var mono: Font
        public var monoSmall: Font

        public init(
            body: Font = .body,
            caption: Font = .caption,
            caption2: Font = .caption2,
            callout: Font = .callout,
            subheadline: Font = .subheadline,
            mono: Font = .system(.callout, design: .monospaced),
            monoSmall: Font = .system(.caption, design: .monospaced)
        ) {
            self.body = body
            self.caption = caption
            self.caption2 = caption2
            self.callout = callout
            self.subheadline = subheadline
            self.mono = mono
            self.monoSmall = monoSmall
        }

        public static let `default` = Fonts()
    }

    public init(
        spacing: Spacing = .default,
        colors: Colors = .default,
        fonts: Fonts = .default
    ) {
        self.spacing = spacing
        self.colors = colors
        self.fonts = fonts
    }

    public static let `default` = StreamdownTheme()

    public static let dark = StreamdownTheme()

    public static let light = StreamdownTheme(
        colors: Colors(
            background: Color(white: 0.98),
            foreground: Color(white: 0.10),
            secondaryBackground: Color(white: 0.95),
            tertiaryBackground: Color(white: 0.92),
            secondaryLabel: Color(white: 0.45),
            tertiaryLabel: Color(white: 0.60),
            mutedForeground: Color(white: 0.45),
            border: Color(white: 0.84),
            separator: Color(white: 0.84),
            card: Color(white: 0.95)
        )
    )
}

private struct StreamdownThemeKey: EnvironmentKey {
    static let defaultValue = StreamdownTheme.default
}

extension EnvironmentValues {
    public var streamdownTheme: StreamdownTheme {
        get { self[StreamdownThemeKey.self] }
        set { self[StreamdownThemeKey.self] = newValue }
    }
}

// MARK: - Automatic Theme Modifier

public struct StreamdownAutomaticThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    public func body(content: Content) -> some View {
        content.environment(\.streamdownTheme, colorScheme == .dark ? .dark : .light)
    }
}

extension View {
    public func streamdownAutomaticTheme() -> some View {
        modifier(StreamdownAutomaticThemeModifier())
    }
}
