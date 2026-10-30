import AgentDockCore
import SwiftUI

struct AnalyticsConsentView: View {
    static func shouldPresent(consent: AnalyticsConsent, isConfigured: Bool) -> Bool {
        isConfigured && consent == .undecided
    }

    @EnvironmentObject private var model: AgentDockModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Help Improve AgentDock?")
                .font(.title2.weight(.semibold))
            Text("Share optional, pseudonymous product analytics. AgentDock works the same if you don't, and nothing is sent unless you choose Allow.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 12) {
                consentLine("Shared", "Feature actions and outcomes, safe error codes, coarse counts and timing buckets, app version, macOS major version, and architecture.", "checkmark.shield")
                consentLine("Never shared", "Names, accounts, paths, commands, prompts, chats, transcripts, session IDs, configuration values, logs, crashes, or location.", "hand.raised")
                consentLine("Your choice", "Change this anytime in Settings › Privacy. Opting out clears pending events and deletes the local analytics identifier.", "switch.2")
            }
            .padding(14)
            .background(.quinary, in: .rect(cornerRadius: 10))

            HStack {
                Spacer()
                Button("Don't Allow") { model.setAnalyticsConsent(granted: false, surface: .onboarding) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { model.setAnalyticsConsent(granted: true, surface: .onboarding) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled()
    }

    private func consentLine(_ title: String, _ detail: String, _ icon: String) -> some View {
        GridRow {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
