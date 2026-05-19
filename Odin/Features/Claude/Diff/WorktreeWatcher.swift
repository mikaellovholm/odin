#if os(macOS)
import Foundation
import CoreServices

/// Recursive FSEvents watcher that fires a debounced callback whenever any
/// file inside `path` changes. Ignores `.git/` paths so git's own internal
/// writes don't trigger refreshes mid-edit. Owned 1:1 by `DiffViewModel`.
@MainActor
final class WorktreeWatcher {
    private let path: String
    private let onChange: () -> Void
    private let debounceInterval: TimeInterval

    private var stream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?

    init(path: String, debounce: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.path = path
        self.debounceInterval = debounce
        self.onChange = onChange
    }

    deinit {
        // FSEventStream APIs are safe to call from any thread.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func start() {
        guard stream == nil else { return }
        let info = Unmanaged.passUnretained(self).toOpaque()
        var ctx = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { (_, info, numEvents, eventPaths, _, _) in
            guard let info else { return }
            let watcher = Unmanaged<WorktreeWatcher>.fromOpaque(info).takeUnretainedValue()
            // eventPaths is a CFArrayRef of CFStringRef when kFSEventStreamCreateFlagUseCFTypes
            // is set; otherwise a `char **`. We're not passing UseCFTypes, so it's char **.
            let paths = eventPaths
                .assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var hasRelevantChange = false
            for i in 0..<numEvents {
                let cstr = paths[i]
                let s = String(cString: cstr)
                if s.range(of: "/.git/") != nil || s.hasSuffix("/.git") {
                    continue
                }
                hasRelevantChange = true
                break
            }
            if hasRelevantChange {
                DispatchQueue.main.async {
                    watcher.scheduleNotify()
                }
            }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &ctx,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // Latency 0 — we do our own debouncing in Swift so we don't miss
            // the leading edge of a burst.
            0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents
            )
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    private func scheduleNotify() {
        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
#endif
