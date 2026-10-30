import AppKit
import AgentDockCore
import SwiftUI
import UniformTypeIdentifiers

struct EditProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AgentDockModel
    let profile: CodexProfile

    @State private var name: String
    @State private var iconKind: ProfileIconKind
    @State private var iconValue: String
    @State private var iconColor: String
    @State private var customIconData: Data?
    @FocusState private var nameFocused: Bool

    init(profile: CodexProfile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _iconKind = State(initialValue: profile.iconKind)
        _iconValue = State(initialValue: profile.iconValue)
        _iconColor = State(initialValue: profile.iconColor)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .focused($nameFocused)
                    .onSubmit(save)
                LabeledContent("Provider", value: profile.product.displayName)
            } header: {
                Text("Edit Profile")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .textCase(nil)
            }

            ProfileAppearanceEditor(
                name: name,
                iconKind: $iconKind,
                iconValue: $iconValue,
                iconColor: $iconColor,
                customIconData: $customIconData,
                existingImageURL: profile.customIconPath
            )

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.storeMutationInProgress)
        .frame(width: 500)
        .frame(minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    model.errorMessage = nil
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                HStack {
                    if model.storeMutationInProgress {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving profile")
                    }
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty || model.storeMutationInProgress)
                }
            }
        }
        .onAppear {
            nameFocused = true
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedName.isEmpty, !model.storeMutationInProgress else { return }
        model.updateProfile(
            profile,
            name: trimmedName,
            color: Color(hex: iconColor),
            iconKind: iconKind,
            iconValue: iconValue,
            customIconData: customIconData
        )
    }
}

/// A named swatch, so color choices are announced by name rather than hex value.
struct ProfileColorChoice: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }

    static let choices = [
        ProfileColorChoice(name: "Blue", hex: "#2563EB"),
        ProfileColorChoice(name: "Indigo", hex: "#4F46E5"),
        ProfileColorChoice(name: "Purple", hex: "#9333EA"),
        ProfileColorChoice(name: "Pink", hex: "#DB2777"),
        ProfileColorChoice(name: "Red", hex: "#E5484D"),
        ProfileColorChoice(name: "Orange", hex: "#F97316"),
        ProfileColorChoice(name: "Yellow", hex: "#EAB308"),
        ProfileColorChoice(name: "Green", hex: "#16A34A"),
        ProfileColorChoice(name: "Teal", hex: "#0D9488"),
        ProfileColorChoice(name: "Graphite", hex: "#6B7280")
    ]
}

struct ProfileAppearanceEditor: View {
    let name: String
    @Binding var iconKind: ProfileIconKind
    @Binding var iconValue: String
    @Binding var iconColor: String
    @Binding var customIconData: Data?
    let existingImageURL: URL?
    @State private var previewImage: NSImage?
    @State private var choosingImage = false
    @State private var imageSelectionError: String?

    private let symbols = [
        "person.fill", "briefcase.fill", "house.fill", "building.2.fill", "star.fill", "flag.fill",
        "bolt.fill", "flask.fill", "hammer.fill", "terminal.fill",
        "chevron.left.forwardslash.chevron.right", "globe", "graduationcap.fill", "heart.fill"
    ]

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                ProfileIconArtwork(
                    name: name,
                    kind: iconKind,
                    value: iconValue,
                    color: iconColor,
                    image: previewImage,
                    size: 64
                )
                Picker("Style", selection: $iconKind) {
                    Text("Letter").tag(ProfileIconKind.monogram)
                    Text("Symbol").tag(ProfileIconKind.symbol)
                    Text("Image").tag(ProfileIconKind.image)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, 4)

            switch iconKind {
            case .monogram:
                TextField("Letter", text: monogramBinding, prompt: Text(defaultMonogram))
            case .symbol:
                symbolGrid
            case .image:
                LabeledContent("Image") {
                    Button(previewImage == nil ? "Choose Image…" : "Replace Image…") { choosingImage = true }
                }
                if let imageSelectionError {
                    Label(imageSelectionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if iconKind != .image {
                LabeledContent("Color") {
                    HStack(spacing: 8) {
                        ForEach(ProfileColorChoice.choices) { choice in
                            swatch(choice)
                        }
                        ColorPicker("Custom Color", selection: colorBinding, supportsOpacity: false)
                            .labelsHidden()
                            .help("Custom Color")
                    }
                }
            }
        } header: {
            Text("Icon")
        } footer: {
            Text("The sidebar and the profile's Dock shortcut use the same icon.")
        }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.png, .jpeg, .heic]) { result in
            if case let .success(url) = result { loadImage(at: url) }
        }
        .task(id: existingImageURL) {
            if customIconData == nil, let existingImageURL {
                previewImage = IconImageCache.profileImage(at: existingImageURL)
            }
        }
    }

    private var symbolGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
            ForEach(symbols, id: \.self) { symbol in
                let selected = (iconValue.isEmpty ? "person.fill" : iconValue) == symbol
                Button {
                    iconValue = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.title3)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                                    in: .rect(cornerRadius: 7))
                        .overlay {
                            if selected {
                                RoundedRectangle(cornerRadius: 7).strokeBorder(.tint, lineWidth: 1.5)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " "))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }

    private func swatch(_ choice: ProfileColorChoice) -> some View {
        let selected = iconColor.caseInsensitiveCompare(choice.hex) == .orderedSame
        return Button {
            iconColor = choice.hex
        } label: {
            Circle()
                .fill(Color(hex: choice.hex))
                .frame(width: 18, height: 18)
                .overlay {
                    if selected {
                        Circle().strokeBorder(.white, lineWidth: 2)
                            .padding(-0.5)
                    }
                }
                .padding(2)
                .overlay {
                    if selected { Circle().strokeBorder(Color(hex: choice.hex), lineWidth: 1.5) }
                }
        }
        .buttonStyle(.plain)
        .help(choice.name)
        .accessibilityLabel(choice.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var defaultMonogram: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private var monogramBinding: Binding<String> {
        Binding(
            get: { iconValue },
            set: { iconValue = String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased() }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(hex: iconColor) }, set: { iconColor = $0.hexString })
    }

    private func loadImage(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard
            let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let fileSize = resourceValues.fileSize,
            fileSize <= 10 * 1_024 * 1_024,
            let data = try? Data(contentsOf: url),
            let image = NSImage(data: data),
            image.isValid
        else {
            imageSelectionError = "Choose a PNG, JPEG, or HEIC image no larger than 10 MB."
            return
        }
        imageSelectionError = nil
        customIconData = data
        previewImage = image
        iconKind = .image
    }
}
