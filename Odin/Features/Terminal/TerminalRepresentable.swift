import SwiftUI
import SwiftTerm

#if os(iOS)
struct TerminalRepresentable: UIViewRepresentable {
    var onTerminalViewCreated: (TerminalView) -> Void
    var onDataSend: (ArraySlice<UInt8>) -> Void
    var onSizeChanged: (Int, Int) -> Void
    var isConnected: Bool

    func makeUIView(context: Context) -> OdinTerminalView {
        let tv = OdinTerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = .white
        tv.backgroundColor = .black
        tv.isOpaque = true
        tv.font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        context.coordinator.terminalView = tv
        onTerminalViewCreated(tv)
        return tv
    }

    func updateUIView(_ uiView: OdinTerminalView, context: Context) {
        if isConnected && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDataSend: onDataSend, onSizeChanged: onSizeChanged)
    }
}

/// Subclass that adds mouse wheel event support for tmux scrolling on iOS.
/// SwiftTerm's iOS implementation only sends button-1 drag events, not wheel events.
/// We add a pan gesture that translates vertical swipes into SGR mouse wheel
/// escape sequences (buttons 64/65) so tmux scroll works.
class OdinTerminalView: TerminalView, UIGestureRecognizerDelegate {
    private var lastAppliedSize: CGSize = .zero
    private var scrollAccumulator: CGFloat = 0
    private let pixelsPerScrollLine: CGFloat = 20
    private var wheelGesture: UIPanGestureRecognizer?

    /// Ensure standard keyboard every time focus is acquired
    override func becomeFirstResponder() -> Bool {
        inputView = nil
        return super.becomeFirstResponder()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard wheelGesture == nil, superview != nil else { return }
        inputView = nil
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleWheelPan(_:)))
        gesture.delegate = self
        wheelGesture = gesture
        addGestureRecognizer(gesture)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let newSize = bounds.size
        if newSize != lastAppliedSize && newSize.width > 0 && newSize.height > 0 {
            lastAppliedSize = newSize
        }
    }

    /// Block UIScrollView's native pan when mouse mode is active.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if getTerminal().mouseMode != .off && gestureRecognizer === panGestureRecognizer {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// Allow our wheel gesture to run simultaneously with SwiftTerm's gestures.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === wheelGesture
    }

    @objc private func handleWheelPan(_ gesture: UIPanGestureRecognizer) {
        guard getTerminal().mouseMode != .off else { return }

        switch gesture.state {
        case .began:
            scrollAccumulator = 0
        case .changed:
            let delta = gesture.translation(in: self).y
            gesture.setTranslation(.zero, in: self)
            scrollAccumulator += delta

            while abs(scrollAccumulator) >= pixelsPerScrollLine {
                if scrollAccumulator < 0 {
                    // Swipe up → scroll up (button 64)
                    sendWheelEvent(button: 64)
                    scrollAccumulator += pixelsPerScrollLine
                } else {
                    // Swipe down → scroll down (button 65)
                    sendWheelEvent(button: 65)
                    scrollAccumulator -= pixelsPerScrollLine
                }
            }
        default:
            scrollAccumulator = 0
        }
    }

    /// Send a mouse wheel event as SGR escape sequence: \e[<button;col;rowM
    private func sendWheelEvent(button: Int) {
        let seq = "\u{1b}[<\(button);1;1M"
        let bytes = Array(seq.utf8)
        terminalDelegate?.send(source: self, data: bytes[...])
    }
}

#else
struct TerminalRepresentable: NSViewRepresentable {
    var onTerminalViewCreated: (TerminalView) -> Void
    var onDataSend: (ArraySlice<UInt8>) -> Void
    var onSizeChanged: (Int, Int) -> Void
    var isConnected: Bool

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = .white
        context.coordinator.terminalView = tv
        onTerminalViewCreated(tv)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        if isConnected {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDataSend: onDataSend, onSizeChanged: onSizeChanged)
    }
}
#endif

extension TerminalRepresentable {
    class Coordinator: NSObject, TerminalViewDelegate {
        let onDataSend: (ArraySlice<UInt8>) -> Void
        let onSizeChanged: (Int, Int) -> Void
        weak var terminalView: TerminalView?

        init(onDataSend: @escaping (ArraySlice<UInt8>) -> Void,
             onSizeChanged: @escaping (Int, Int) -> Void) {
            self.onDataSend = onDataSend
            self.onSizeChanged = onSizeChanged
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onDataSend(data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onSizeChanged(newCols, newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
