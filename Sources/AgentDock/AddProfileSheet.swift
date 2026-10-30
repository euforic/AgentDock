import AgentDockCore
import SwiftUI

struct AddProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AgentDockModel
    @State private var product: DesktopProduct = .codex
    @State private var name = ""
    @State private var iconKind: ProfileIconKind = .monogram
    @State private var iconValue = ""
    @State private var iconColor = ProfileColorChoice.choices[0].hex
    @State private var customIconData: Data?
    @State private var isSubmitting = false
    @State private var creationTask: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $product) {
                    ForEach(DesktopProduct.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                TextField("Name", text: $name, prompt: Text("Personal"))
                    .focused($nameFocused)
                    .onSubmit(submit)
            } header: {
                Text("Add Profile")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            } footer: {
                Text("After you create the profile, open it and sign in with the account you want to use.")
            }

            ProfileAppearanceEditor(
                name: name,
                iconKind: $iconKind,
                iconValue: $iconValue,
                iconColor: $iconColor,
                customIconData: $customIconData,
                existingImageURL: nil
            )

            Section {
                Label(
                    "Each profile has separate provider app data and sign-in. Your Keychain, files, shell, network, Git, and SSH stay shared.",
                    systemImage: "lock"
                )
                .foregroundStyle(.secondary)
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isSubmitting)
        .frame(width: 500)
        .frame(minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    creationTask?.cancel()
                    model.errorMessage = nil
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                HStack {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Creating profile")
                    }
                    Button("Create Profile", action: submit)
                        .disabled(trimmedName.isEmpty || isSubmitting || model.storeMutationInProgress)
                }
            }
        }
        .task {
            product = model.selectedProfile?.product ?? model.selectedOfficialProduct ?? .codex
            nameFocused = true
        }
        .onDisappear {
            creationTask?.cancel()
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedName.isEmpty, !isSubmitting, !model.storeMutationInProgress else { return }
        isSubmitting = true
        model.errorMessage = nil
        let requestedProduct = product
        let requestedName = trimmedName
        let requestedColor = Color(hex: iconColor)
        let requestedIconKind = iconKind
        let requestedIconValue = iconValue
        let requestedCustomIconData = customIconData

        creationTask = Task { @MainActor in
            let created = await model.addProfile(
                product: requestedProduct,
                name: requestedName,
                color: requestedColor,
                iconKind: requestedIconKind,
                iconValue: requestedIconValue,
                customIconData: requestedCustomIconData
            )
            guard !Task.isCancelled else { return }
            isSubmitting = false
            creationTask = nil
            if created {
                dismiss()
            }
        }
    }
}
