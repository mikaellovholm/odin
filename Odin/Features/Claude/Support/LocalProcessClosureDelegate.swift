#if os(macOS)
import Foundation
import SwiftTerm

/// Closure-based `LocalProcessDelegate` shared by `LocalTerminalViewModel`
/// (Claude PTYs) and `ShellTerminalViewModel` (per-session zsh panes). The
/// `LocalProcess` init configures the delegate queue to the main dispatch
/// queue, so every callback lands on the main actor — we use
/// `MainActor.assumeIsolated` to satisfy the compiler without an actor hop.
///
/// The class is `@unchecked Sendable` because the closures it stores are
/// `@MainActor`-isolated effectively (all reads/writes happen from the main
/// queue) and `LocalProcess` retains the delegate from a non-isolated context
/// during its own initialisation.
@MainActor
final class LocalProcessClosureDelegate: LocalProcessDelegate, @unchecked Sendable {
    let onData: (ArraySlice<UInt8>) -> Void
    let onTerminated: (Int32?) -> Void
    let onGetWindowSize: () -> winsize

    init(
        onData: @escaping (ArraySlice<UInt8>) -> Void,
        onTerminated: @escaping (Int32?) -> Void,
        onGetWindowSize: @escaping () -> winsize
    ) {
        self.onData = onData
        self.onTerminated = onTerminated
        self.onGetWindowSize = onGetWindowSize
    }

    nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated { self.onTerminated(exitCode) }
    }

    nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { self.onData(slice) }
    }

    nonisolated func getWindowSize() -> winsize {
        MainActor.assumeIsolated { self.onGetWindowSize() }
    }
}
#endif
