import SwiftUI

struct TerminalContainerView: View {
    @Binding var selectedTab: AppTab
    @State private var viewModel = TerminalViewModel()
    @State private var keyboardDismissed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Terminal always in the hierarchy to preserve state
            TerminalRepresentable(
                onTerminalViewCreated: { viewModel.setTerminalView($0) },
                onDataSend: { viewModel.sendData($0) },
                onSizeChanged: { viewModel.resizeTerminal(cols: $0, rows: $1) },
                isConnected: viewModel.state == .connected,
                keyboardDismissed: $keyboardDismissed
            )
            .opacity(viewModel.state == .connected ? 1 : 0)

            // Overlay for non-connected states
            if viewModel.state != .connected {
                stateOverlay
            }

            // Toolbar buttons when connected
            #if os(iOS)
            if viewModel.state == .connected {
                VStack(spacing: 12) {
                    Button {
                        keyboardDismissed = true
                        viewModel.terminalView?.resignFirstResponder()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color(red: 0.06, green: 0.11, blue: 0.18), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Button {
                        selectedTab = .todos
                    } label: {
                        Image(systemName: "checklist")
                            .font(.system(size: 20))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color(red: 0.06, green: 0.11, blue: 0.18), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.trailing, 12)
                .padding(.top, 80)
            }
            #endif
        }
        .ignoresSafeArea(.container)
        .background(.black)
        #if os(iOS)
        .toolbar(viewModel.state == .connected ? .hidden : .visible, for: .tabBar)
        #endif
        .onAppear {
            if viewModel.state == .idle {
                viewModel.connect()
            }
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch viewModel.state {
        case .idle, .checkingKey:
            ProgressView("Checking SSH key...")

        case .setupRequired:
            setupView

        case .startingVM(let status):
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text(status)
                    .foregroundStyle(.secondary)
                Text("Cold start takes 20-40 seconds")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Cancel") {
                    viewModel.cancelConnect()
                }
                .buttonStyle(.bordered)
            }

        case .connecting:
            VStack(spacing: 16) {
                ProgressView("Connecting via SSH...")
                Button("Cancel") {
                    viewModel.cancelConnect()
                }
                .buttonStyle(.bordered)
            }

        case .connected:
            EmptyView()

        case .disconnected:
            VStack(spacing: 16) {
                Image(systemName: "wifi.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Disconnected")
                    .font(.headline)
                Text("tmux session is preserved on the server")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reconnect") {
                    viewModel.connect()
                }
                .buttonStyle(.borderedProminent)
            }

        case .error(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Connection Error")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") {
                    viewModel.connect()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var setupView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "key")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("Terminal Setup")
                    .font(.title2.bold())

                // API Key section
                if !viewModel.hasAPIKey {
                    Text("Enter the API key for the Cloud Function:")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    TextField("API Key", text: $viewModel.apiKeyInput)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()

                    Button("Save API Key") {
                        viewModel.saveAPIKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // SSH Key section
                else if viewModel.publicKey.isEmpty && !SSHKeyManager.hasKey() {
                    Text("Generate an SSH key to connect to the VM.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Generate SSH Key") {
                        viewModel.generateKey()
                    }
                    .buttonStyle(.borderedProminent)
                } else if !viewModel.publicKey.isEmpty {
                    Text("Copy the public key below and add it to GCP:")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(viewModel.publicKey)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)

                    Button("Copy to Clipboard") {
                        copyToClipboard(viewModel.publicKey)
                    }

                    Text("Then run:")
                        .foregroundStyle(.secondary)

                    Text("gcloud compute os-login ssh-keys add --key='<paste>'")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

                    Button("Done, Connect") {
                        viewModel.connect()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    // Has both API key and SSH key
                    Button("Connect") {
                        viewModel.connect()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    private func copyToClipboard(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
