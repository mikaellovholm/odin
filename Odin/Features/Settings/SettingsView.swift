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
