#if os(macOS)
import SwiftTerm
import Foundation

@Observable
@MainActor
final class LocalTerminalViewModel {
    enum State: Equatable {
        case notStarted
        case starting
        case running
        case exited(code: Int32?)
        case error(String)
    }

    var state: State = .notStarted
    var workingDirectory: String = NSHomeDirectory()
    var isActive: Bool = false
    var didFinish: Bool = false

    private var process: LocalProcess?
    private var bridge: ProcessBridge?
    private(set) weak var terminalView: TerminalView?

    func setTerminalView(_ tv: TerminalView) {
        terminalView = tv
    }

    func startClaude() {
        guard let claudePath = Self.resolveClaudePath() else {
            state = .error("claude CLI not found.\nInstall with: npm install -g @anthropic-ai/claude-code")
            return
        }

        let bridge = ProcessBridge(
            onData: { [weak self] slice in
                self?.terminalView?.feed(byteArray: slice)
            },
            onTerminated: { [weak self] exitCode in
                self?.state = .exited(code: exitCode)
                self?.process = nil
            },
            onGetWindowSize: { [weak self] in
                guard let tv = self?.terminalView else {
                    return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
                }
                let terminal = tv.getTerminal()
                return winsize(
                    ws_row: UInt16(clamping: max(terminal.rows, 1)),
                    ws_col: UInt16(clamping: max(terminal.cols, 1)),
                    ws_xpixel: UInt16(clamping: Int(tv.frame.width)),
                    ws_ypixel: UInt16(clamping: Int(tv.frame.height))
                )
            }
        )
        self.bridge = bridge

        let proc = LocalProcess(delegate: bridge, dispatchQueue: .main)
        process = proc
        proc.startProcess(
            executable: claudePath,
            args: [],
            environment: Self.buildEnvironment(),
            execName: nil,
            currentDirectory: workingDirectory
        )
        state = .running
    }

    func sendData(_ data: ArraySlice<UInt8>) {
        process?.send(data: data)
    }

    func resizeTerminal(cols: Int, rows: Int) {
        guard let process, process.running else { return }
        let safeCols = UInt16(clamping: max(cols, 1))
        let safeRows = UInt16(clamping: max(rows, 1))
        var size = winsize(ws_row: safeRows, ws_col: safeCols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(process.childfd, TIOCSWINSZ, &size)
    }

    /// Claude Code signals its state via the terminal title prefix:
    /// ✳ (U+2733) = idle/waiting for input
    /// ⠂ (U+2802) / ⠐ (U+2810) = actively working
    func handleTitleChanged(_ title: String) {
        guard let first = title.first else { return }
        let wasActive = isActive
        switch first {
        case "\u{2802}", "\u{2810}":
            isActive = true
        default:
            isActive = false
        }
        if wasActive && !isActive {
            didFinish = true
        }
    }

    func clearFinished() {
        didFinish = false
    }

    func terminate() {
        process?.terminate()
    }

    func restart() {
        process = nil
        bridge = nil
        didFinish = false
        terminalView?.getTerminal().resetToInitialState()
        startClaude()
    }

    // MARK: - Path Resolution

    private static func resolveClaudePath() -> String? {
        let knownPaths = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
        ]
        for path in knownPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fall back to login shell to resolve PATH (handles nvm, homebrew, etc.)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "which claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }

    private static func buildEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }
    }
}

// MARK: - Process Delegate Bridge

/// Bridges LocalProcessDelegate callbacks to closures.
/// All callbacks execute on the main dispatch queue (set via LocalProcess init).
@MainActor
private final class ProcessBridge: LocalProcessDelegate, @unchecked Sendable {
    let onData: (ArraySlice<UInt8>) -> Void
    let onTerminated: (Int32?) -> Void
    let onGetWindowSize: () -> winsize

    init(onData: @escaping (ArraySlice<UInt8>) -> Void,
         onTerminated: @escaping (Int32?) -> Void,
         onGetWindowSize: @escaping () -> winsize) {
        self.onData = onData
        self.onTerminated = onTerminated
        self.onGetWindowSize = onGetWindowSize
    }

    nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated {
            self.onTerminated(exitCode)
        }
    }

    nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            self.onData(slice)
        }
    }

    nonisolated func getWindowSize() -> winsize {
        MainActor.assumeIsolated {
            self.onGetWindowSize()
        }
    }
}
#endif
