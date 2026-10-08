import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public typealias StreamdownLinkSafetyCheck = @Sendable (URL) async -> Bool

public struct StreamdownLinkSafetyConfig: Sendable {
    public let enabled: Bool
    public let onLinkCheck: StreamdownLinkSafetyCheck?

    public init(enabled: Bool = true, onLinkCheck: StreamdownLinkSafetyCheck? = nil) {
        self.enabled = enabled
        self.onLinkCheck = onLinkCheck
    }

    public static let enabled = StreamdownLinkSafetyConfig(enabled: true)
    public static let disabled = StreamdownLinkSafetyConfig(enabled: false)
}

public struct StreamdownLinkSafetyModal: View {
    let url: String
    @Binding var isPresented: Bool
    let onOpen: () -> Void

    @Environment(\.streamdownTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    public init(
        url: String,
        isPresented: Binding<Bool>,
        onOpen: @escaping () -> Void
    ) {
        self.url = url
        self._isPresented = isPresented
        self.onOpen = onOpen
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }
                .allowsHitTesting(true)

            VStack(alignment: .leading, spacing: theme.spacing.md) {
                HStack(alignment: .top) {
                    Label("Open External Link", systemImage: "link")
                        .font(theme.fonts.callout.weight(.semibold))
                        .foregroundStyle(theme.colors.foreground)
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(theme.colors.mutedForeground)
                    }
                    .buttonStyle(.plain)
                }

                Text("This link is not automatically opened.")
                    .font(theme.fonts.caption)
                    .foregroundStyle(theme.colors.mutedForeground)

                Text(url)
                    .font(theme.fonts.monoSmall)
                    .foregroundStyle(theme.colors.foreground)
                    .lineLimit(4)
                    .padding(theme.spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.colors.tertiaryBackground, in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: theme.spacing.sm) {
                    Button(action: copyLink) {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "Copied" : "Copy")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, theme.spacing.sm)
                        .background(theme.colors.secondaryBackground, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(theme.colors.foreground)
                    }
                    .buttonStyle(.plain)

                    Button(action: openAndDismiss) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text("Open")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, theme.spacing.sm)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(theme.spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.colors.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.colors.separator, lineWidth: 1)
                    )
            )
            .padding(theme.spacing.base)
            .frame(maxWidth: 420)
        }
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isPresented)
    }

    private func copyLink() {
        #if canImport(UIKit)
        UIPasteboard.general.string = url
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func openAndDismiss() {
        onOpen()
        isPresented = false
    }
}
