import SwiftUI
import SwiftTerm

@Observable
@MainActor
final class TerminalViewModel {
    /// `@AppStorage` key for the SSH username — exposed so Settings can bind
    /// the same key. Default is empty so a fresh install lands in the setup
    /// flow rather than connecting as some hard-coded user.
    static let sshUsernameKey = "ssh.username"
    private static let sshPort = 22

    private static var sshUsername: String {
        UserDefaults.standard.string(forKey: sshUsernameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Auto-reconnect schedule (seconds) for unexpected drops. Caps at 30 s so
    /// the app keeps trying for as long as the user leaves the tab open
    /// without hammering the Cloud Function while the VM is reprovisioning.
    private static let reconnectBackoff: [TimeInterval] = [2, 5, 10, 20, 30]

    enum State: Equatable {
        case idle
        case checkingKey
        case setupRequired
        case startingVM(status: String)
        case connecting
        case connected
        case disconnected
        case reconnecting(attempt: Int, retryIn: Int)
        case error(String)
    }

    var state: State = .idle
    var publicKey: String = ""
    var apiKeyInput: String = ""
    var hasAPIKey: Bool = APIKeyManager.get() != nil
    /// Set when `VMStarterService` raises `.rateLimited` — carries the
    /// Cloud-Function-supplied deadline so the error overlay can render a
    /// live countdown and gate the Retry button on the timer expiring.
    /// Cleared on `connect()` so a retry doesn't keep showing stale state.
    var rateLimitedRetryAt: Date?

    private let sshService = SSHService()
    private(set) weak var terminalView: TerminalView?
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// True when the user explicitly disconnected or cancelled — suppresses
    /// auto-reconnect so a single tap on "Cancel" doesn't immediately trigger
    /// another connection attempt.
    private var userInitiatedDisconnect: Bool = false
    private var reconnectAttempt: Int = 0

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
                        self?.handleUnexpectedDisconnect()
                    }
                }
            )
        }
    }

    func connect() {
        userInitiatedDisconnect = false
        reconnectAttempt = 0
        rateLimitedRetryAt = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTask?.cancel()
        connectTask = Task { await performConnect() }
    }

    private func performConnect() async {
        state = .checkingKey

        guard SSHKeyManager.hasKey(),
              APIKeyManager.get() != nil,
              !Self.sshUsername.isEmpty else {
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
        } catch VMStarterService.VMStarterError.rateLimited(let retryAfter) {
            // Stash a deadline so the overlay can render a countdown and
            // disable Retry until the window elapses. Falls back to a 60s
            // hold when the server didn't send Retry-After.
            let delay = TimeInterval(retryAfter ?? 60)
            rateLimitedRetryAt = Date().addingTimeInterval(delay)
            state = .error(VMStarterService.VMStarterError.rateLimited(retryAfter: retryAfter).errorDescription ?? "Rate limited")
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
            reconnectAttempt = 0
        } catch is CancellationError {
            return
        } catch {
            // Skip the .error overlay if we're about to auto-reconnect — it
            // would only flash for a split second before being replaced by
            // the .reconnecting overlay. Show .error only when retries are
            // suppressed (user-initiated disconnect/cancel).
            if userInitiatedDisconnect {
                state = .error("SSH failed: \(error.localizedDescription)")
            } else {
                scheduleAutoReconnect()
            }
        }
    }

    /// Called by the SSH service when the channel drops outside of an explicit
    /// disconnect/cancel. tmux on the VM preserves the user's session, so a
    /// silent reconnect just rejoins the same screen.
    private func handleUnexpectedDisconnect() {
        guard !userInitiatedDisconnect else { return }
        guard state == .connected || isReconnectableState() else { return }
        state = .disconnected
        scheduleAutoReconnect()
    }

    private func isReconnectableState() -> Bool {
        switch state {
        case .connected, .disconnected, .reconnecting, .error:
            return true
        default:
            return false
        }
    }

    private func scheduleAutoReconnect() {
        guard !userInitiatedDisconnect else { return }
        let attempt = reconnectAttempt
        let delay = Self.reconnectBackoff[min(attempt, Self.reconnectBackoff.count - 1)]
        reconnectAttempt = attempt + 1
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            for remaining in stride(from: Int(delay), through: 1, by: -1) {
                if Task.isCancelled || userInitiatedDisconnect { return }
                state = .reconnecting(attempt: attempt + 1, retryIn: remaining)
                try? await Task.sleep(for: .seconds(1))
            }
            if Task.isCancelled || userInitiatedDisconnect { return }
            connectTask?.cancel()
            connectTask = Task { await performConnect() }
        }
    }

    func cancelConnect() {
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
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
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connectTask?.cancel()
        connectTask = nil
        Task { await sshService.disconnect() }
        state = .disconnected
    }
}
