#if os(macOS)
import SwiftTerm
import Foundation

@Observable
@MainActor
final class ShellTerminalViewModel {
    enum State: Equatable {
        case notStarted
        case running
        case exited(code: Int32?)
        case error(String)
    }

    var state: State = .notStarted
    var workingDirectory: String = NSHomeDirectory()

    private var process: LocalProcess?
    private var bridge: LocalProcessClosureDelegate?
    private(set) weak var terminalView: TerminalView?

    /// Monotonically bumped on every `start()`. Each launch captures its token
    /// so a late `onTerminated` from a previously-replaced bridge becomes a
    /// no-op instead of overwriting the new process's `.running` state.
    private var currentLaunchToken: UInt64 = 0

    func setTerminalView(_ tv: TerminalView) {
        terminalView = tv
    }

    func startIfNeeded() {
        guard state == .notStarted else { return }
        start()
    }

    func start() {
        // Stamp this launch so a late `onTerminated` from a previous bridge
        // (e.g. SIGTERM landing after we've already kicked off a new shell in
        // `restart()`) can't clobber the new `.running` state.
        currentLaunchToken &+= 1
        let launchToken = currentLaunchToken

        let bridge = LocalProcessClosureDelegate(
            onData: { [weak self] slice in
                self?.terminalView?.feed(byteArray: slice)
            },
            onTerminated: { [weak self] exitCode in
                guard let self, self.currentLaunchToken == launchToken else { return }
                self.state = .exited(code: exitCode)
                self.process = nil
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

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let envArray = env.map { "\($0.key)=\($0.value)" }

        proc.startProcess(
            executable: "/bin/zsh",
            args: ["-l"],
            environment: envArray,
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

    func restart() {
        // Detach the old bridge: bump the token so its pending `onTerminated`
        // (delivered async after SIGTERM lands) can't overwrite the new
        // launch's state. `start()` will bump again to mint the new token.
        currentLaunchToken &+= 1
        process?.terminate()
        process = nil
        bridge = nil
        terminalView?.getTerminal().resetToInitialState()
        start()
    }

    func terminate() {
        // Same detachment as `restart()`: any late `.exited` callback from the
        // old bridge must not clobber `.notStarted` below.
        currentLaunchToken &+= 1
        process?.terminate()
        process = nil
        bridge = nil
        state = .notStarted
    }
}

#endif
