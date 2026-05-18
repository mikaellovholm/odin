import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.appearanceKey) private var appearance: AppearanceMode = .system
    @AppStorage(AppSettings.accentColorKey) private var accent: AppAccent = .blue
    @AppStorage(TerminalFontSettings.key) private var terminalFontSize: Double = Double(TerminalFontSettings.defaultSize)

    @State private var biometricEnabled = SSHKeyManager.biometricProtectionEnabled
    @State private var biometricError: String?

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
                    Text("Generate an SSH key in the Terminal tab first.")
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
