import CodexerCore
import SwiftUI

struct AnalyticsConsentView: View {
    static func shouldPresent(consent: AnalyticsConsent, isConfigured: Bool) -> Bool {
        isConfigured && consent == .undecided
    }

    @EnvironmentObject private var model: CodexerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 30))
                .foregroundStyle(AgentDockPalette.blue)
            Text("Help improve AgentDock?")
                .font(.system(size: 22, weight: .semibold))
            Text("Share optional, pseudonymous product analytics. AgentDock is fully functional if you say no, and nothing is sent until you choose Allow Analytics.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                consentLine("Shared", "Feature actions and outcomes, safe error codes, coarse counts and timing buckets, app version, macOS major version, and architecture.", "checkmark.shield")
                consentLine("Never shared", "Names, accounts, paths, commands, prompts, chats, transcripts, session IDs, configuration values, logs, crashes, or precise location.", "hand.raised")
                consentLine("Your control", "Turn this off at any time in Data & Privacy. Opting out immediately clears pending events and deletes the local analytics identifier.", "switch.2")
            }
            .padding(14)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Button("No Thanks") { model.setAnalyticsConsent(granted: false, surface: .onboarding) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow Analytics") { model.setAnalyticsConsent(granted: true, surface: .onboarding) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 540)
        .background(AgentDockPalette.graphite)
        .interactiveDismissDisabled()
    }

    private func consentLine(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}
