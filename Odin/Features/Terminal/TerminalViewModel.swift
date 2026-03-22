import SwiftUI
import SwiftTerm

@Observable
@MainActor
final class TerminalViewModel {
    private static let sshUsername = "mikael_lovholm_gmail_com"
    private static let sshPort = 22

    enum State: Equatable {
        case idle
        case checkingKey
        case setupRequired
        case startingVM(status: String)
        case connecting
        case connected
        case disconnected
        case error(String)
    }

    var state: State = .idle
    var publicKey: String = ""
    var apiKeyInput: String = ""
    var hasAPIKey: Bool = APIKeyManager.get() != nil

    private let sshService = SSHService()
    private(set) weak var terminalView: TerminalView?
    private var connectTask: Task<Void, Never>?

    func setTerminalView(_ tv: TerminalView) {
        terminalView = tv
        Task {
            await sshService.setCallbacks(
                onDataReceived: { [weak self] bytes in
                    Task { @MainActor in
                        self?.terminalView?.feed(byteArray: bytes[...])
                    }
                },
                onDisconnected: { [weak self] in
                    Task { @MainActor in
                        if self?.state == .connected {
                            self?.state = .disconnected
                        }
                    }
                }
            )
        }
    }

    func connect() {
        connectTask?.cancel()
        connectTask = Task { await performConnect() }
    }

    private func performConnect() async {
        state = .checkingKey

        guard SSHKeyManager.hasKey(), APIKeyManager.get() != nil else {
            state = .setupRequired
            return
        }

        state = .startingVM(status: "Starting VM...")

        let vmResult: VMStarterService.VMResult
        do {
            vmResult = try await VMStarterService.startAndWaitForIP()
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            state = .error("VM start failed: \(error.localizedDescription)")
            return
        }

        state = .connecting

        do {
            let privateKey = try SSHKeyManager.getPrivateKey()
            try Task.checkCancellation()

            let terminal = terminalView?.getTerminal()
            let cols = terminal.map { Int($0.cols) } ?? 80
            let rows = terminal.map { Int($0.rows) } ?? 24

            try await sshService.connect(
                host: vmResult.ip,
                port: Self.sshPort,
                username: Self.sshUsername,
                privateKey: privateKey,
                cols: cols,
                rows: rows,
                expectedHostKey: vmResult.hostKey
            )
            state = .connected
        } catch is CancellationError {
            return
        } catch {
            state = .error("SSH failed: \(error.localizedDescription)")
        }
    }

    func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        state = .idle
    }

    func generateKey() {
        do {
            try SSHKeyManager.generateKey()
            publicKey = try SSHKeyManager.getPublicKeyOpenSSH()
        } catch {
            state = .error("Key generation failed: \(error.localizedDescription)")
        }
    }

    func saveAPIKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try APIKeyManager.save(key)
            hasAPIKey = true
        } catch {
            state = .error("Failed to save API key: \(error.localizedDescription)")
        }
    }

    func sendData(_ data: ArraySlice<UInt8>) {
        Task { await sshService.write(data) }
    }

    func resizeTerminal(cols: Int, rows: Int) {
        Task { await sshService.resize(cols: cols, rows: rows) }
    }

    func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        Task { await sshService.disconnect() }
        state = .disconnected
    }
}
