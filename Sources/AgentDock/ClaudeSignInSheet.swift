import AppKit
import SwiftUI

/// Guides adding a Claude account with AgentDock's own sign-in: the browser
/// step, an optional pasted code, the token exchange, and a retry after a
/// failure. Signing in to an account already listed replaces its sign-in.
struct ClaudeSignInSheet: View {
    @EnvironmentObject private var model: AgentDockModel
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        Form {
            Section {
                content
            } header: {
                Text("Sign In to Claude")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            } footer: {
                Text("AgentDock keeps each account's sign-in in its own Keychain item and uses it only to read that account's profile and Claude Code usage limits. Sign in with the account you want to add.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.cancelClaudeCodeSignIn() }
            }
            ToolbarItem(placement: .confirmationAction) {
                confirmationButton
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.claudeSignInState {
        case .signingIn(.starting):
            progressRow("Opening your browser…")
        case let .signingIn(.waitingForBrowser(url)):
            Text("Finish signing in in your browser. If claude.ai shows a code, paste it here.")
                .fixedSize(horizontal: false, vertical: true)
            TextField("Code", text: $code)
                .autocorrectionDisabled()
                .focused($codeFocused)
                .onSubmit(submit)
                .onAppear { codeFocused = true }
            Button("Open Browser Again") {
                NSWorkspace.shared.open(url)
            }
        case .signingIn(.exchanging):
            progressRow("Finishing sign-in…")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var confirmationButton: some View {
        switch model.claudeSignInState {
        case .signingIn(.waitingForBrowser):
            Button("Continue", action: submit)
                .disabled(trimmedCode.isEmpty)
        case .failed:
            Button("Try Again") {
                code = ""
                model.signInToClaude()
            }
        default:
            EmptyView()
        }
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedCode.isEmpty else { return }
        model.submitClaudeSignInCode(trimmedCode)
        code = ""
    }
}
