import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.appearanceKey) private var appearance: AppearanceMode = .system
    @AppStorage(AppSettings.accentColorKey) private var accent: AppAccent = .blue
    @AppStorage(TerminalFontSettings.key) private var terminalFontSize: Double = Double(TerminalFontSettings.defaultSize)
    @AppStorage(TerminalViewModel.sshUsernameKey) private var sshUsername: String = ""
    @AppStorage(TerminalViewModel.functionURLKey) private var functionURL: String = ""
    #if os(macOS)
    @AppStorage(ClaudePath.overrideKey) private var claudeBinaryOverride: String = ""
    #endif

    @State private var biometricEnabled = SSHKeyManager.biometricProtectionEnabled
    @State private var biometricError: String?
    @State private var diagnostics = OdinDiagnostics.shared

    // API key replace flow. `apiKeyConfigured` reflects what's in the
    // Keychain; `apiKeyReplacing` is true while the user is entering a
    // replacement. We can't drive the entry UI off `apiKeyInput.isEmpty`
    // alone — clicking Replace and then deleting all input would silently
    // bounce back to the "Saved" branch — so the flag stays separate.
    @State private var apiKeyInput: String = ""
    @State private var apiKeySaveError: String?
    @State private var apiKeyConfigured = APIKeyManager.get() != nil
    @State private var apiKeyReplacing: Bool = false

    // SSH public key — fetched lazily on appear; nil if no key is stored.
    @State private var publicKey: String?
    @State private var publicKeyError: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Picker("Accent color", selection: $accent) {
                    ForEach(AppAccent.allCases) { color in
                        HStack {
                            Circle()
                                .fill(color.color)
                                .frame(width: 12, height: 12)
                            Text(color.label)
                        }
                        .tag(color)
                    }
                }
            }

            Section("Terminal") {
                HStack {
                    Text("Font size")
                    Spacer()
                    Text("\(Int(terminalFontSize)) pt")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $terminalFontSize,
                    in: Double(TerminalFontSettings.minSize)...Double(TerminalFontSettings.maxSize),
                    step: Double(TerminalFontSettings.step)
                )
            }

            Section("Diagnostics") {
                diagnosticsRow(label: "MCP server", status: diagnostics.mcpServer)
                diagnosticsRow(label: "Claude hooks", status: diagnostics.hooks)
                diagnosticsRow(label: "Claude skills", status: diagnostics.skills)
                diagnosticsRow(label: "Notifications", status: diagnostics.notifications)
            }

            Section("Connection") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cloud Function URL")
                    TextField("https://…cloudfunctions.net/…", text: $functionURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                    if !functionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && TerminalViewModel.functionURL == nil {
                        Text("Must be a valid https:// URL.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                HStack {
                    Text("SSH username")
                    Spacer()
                    TextField("user_name", text: $sshUsername)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .frame(maxWidth: 220)
                }
                apiKeySection
                publicKeySection
                #if os(macOS)
                claudeBinarySection
                #endif
            }

            Section {
                Toggle("Require biometric auth for SSH key", isOn: Binding(
                    get: { biometricEnabled },
                    set: { newValue in toggleBiometric(to: newValue) }
                ))
                .disabled(!SSHKeyManager.biometricsAvailable() || !SSHKeyManager.hasKey())
                if !SSHKeyManager.biometricsAvailable() {
                    Text("Biometrics not available on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !SSHKeyManager.hasKey() {
                    Text("Generate an SSH key in the Remote tab first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let biometricError {
                    Text(biometricError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Security")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, minHeight: 420)
        .navigationTitle("Settings")
        .onAppear { loadPublicKey() }
    }

    // MARK: - API key

    @ViewBuilder
    private var apiKeySection: some View {
        if apiKeyConfigured && !apiKeyReplacing {
            HStack {
                Text("Cloud Function API key")
                Spacer()
                Label("Saved", systemImage: "checkmark.seal.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Replace…") {
                    apiKeyReplacing = true
                    apiKeyInput = ""
                    apiKeySaveError = nil
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Cloud Function API key")
                SecureField("API key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                HStack {
                    Button("Save") { saveAPIKey() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if apiKeyConfigured {
                        Button("Cancel") {
                            apiKeyInput = ""
                            apiKeySaveError = nil
                            apiKeyReplacing = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                }
                if let apiKeySaveError {
                    Text(apiKeySaveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try APIKeyManager.save(trimmed)
            apiKeyInput = ""
            apiKeySaveError = nil
            apiKeyConfigured = true
            apiKeyReplacing = false
        } catch {
            apiKeySaveError = error.localizedDescription
        }
    }

    // MARK: - SSH public key

    @ViewBuilder
    private var publicKeySection: some View {
        if let key = publicKey {
            VStack(alignment: .leading, spacing: 6) {
                Text("SSH public key")
                Text(key)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button("Copy to Clipboard") {
                    copyToClipboard(key)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else if let publicKeyError {
            HStack {
                Text("SSH public key")
                Spacer()
                Text(publicKeyError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } else {
            HStack {
                Text("SSH public key")
                Spacer()
                Text("Not generated yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadPublicKey() {
        guard SSHKeyManager.hasKey() else {
            publicKey = nil
            publicKeyError = nil
            return
        }
        // Biometric-protected keys would prompt here — accept that as the
        // cost of letting the user copy the public key from Settings.
        do {
            publicKey = try SSHKeyManager.getPublicKeyOpenSSH()
            publicKeyError = nil
        } catch {
            publicKey = nil
            publicKeyError = error.localizedDescription
        }
    }

    private func copyToClipboard(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    // MARK: - Claude binary (macOS)

    #if os(macOS)
    @ViewBuilder
    private var claudeBinarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Claude binary")
                Spacer()
                Text(ClaudePath.resolve() ?? "not found")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ClaudePath.resolve() == nil ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TextField("Override path (optional)", text: $claudeBinaryOverride)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
            Text("Defaults search: \(ClaudePath.knownPaths.joined(separator: ", "))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }
    #endif

    @ViewBuilder
    private func diagnosticsRow(label: String, status: OdinDiagnostics.Status) -> some View {
        HStack(alignment: .top) {
            Text(label)
            Spacer()
            switch status {
            case .ok:
                Label("OK", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
            case .failed(let msg):
                VStack(alignment: .trailing, spacing: 2) {
                    Label("Failed", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                        .font(.caption.weight(.semibold))
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private func toggleBiometric(to enabled: Bool) {
        biometricError = nil
        do {
            try SSHKeyManager.setBiometricProtection(enabled)
            biometricEnabled = enabled
        } catch {
            biometricError = error.localizedDescription
        }
    }
}

/// Container that applies the persisted theme to its children. Wraps the root
/// scene so appearance + accent flow through the SwiftUI environment.
struct ThemedContainer<Content: View>: View {
    @AppStorage(AppSettings.appearanceKey) private var appearance: AppearanceMode = .system
    @AppStorage(AppSettings.accentColorKey) private var accent: AppAccent = .blue
    let content: () -> Content

    var body: some View {
        content()
            .tint(accent.color)
            .preferredColorScheme(appearance.colorScheme)
    }
}

#if os(macOS)
/// Reaches up to the hosting `NSWindow` and forces it opaque. SwiftUI defaults
/// can leave the window translucent on macOS — once any descendant view uses
/// a vibrant material (`.bar`, `.regularMaterial`, `List(.sidebar)`'s
/// implicit `NSVisualEffectView`), that material can punch through the
/// window's contentView and reveal whatever is behind the app. Setting
/// `isOpaque = true` plus a solid `backgroundColor` shuts that down for the
/// entire window. Sized as a zero-frame, hit-test-disabled background so it
/// doesn't affect layout.
struct OpaqueWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view's window isn't available immediately on creation; defer
        // one runloop tick to make sure the window has been hooked up.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.isOpaque = true
            window.backgroundColor = NSColor.windowBackgroundColor
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
