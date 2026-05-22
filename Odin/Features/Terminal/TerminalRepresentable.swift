import SwiftUI
import SwiftTerm

#if os(iOS)
struct TerminalRepresentable: UIViewRepresentable {
    var onTerminalViewCreated: (TerminalView) -> Void
    var onDataSend: (ArraySlice<UInt8>) -> Void
    var onSizeChanged: (Int, Int) -> Void
    var fontSize: CGFloat = 10
    var isConnected: Bool
    @Binding var keyboardDismissed: Bool
    /// Opt-in `Homebrew` Terminal.app profile (phosphor-green text + caret).
    /// Default is `false` so existing call sites keep their white-on-black look.
    var useHomebrewTheme: Bool = false
    /// Override the terminal's canvas background. Defaults to black; set to
    /// e.g. `TerminalTheme.shellBackground` for the shell pane.
    var backgroundColorOverride: UIColor? = nil

    func makeUIView(context: Context) -> OdinTerminalView {
        let tv = OdinTerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        let bg = backgroundColorOverride ?? .black
        tv.nativeBackgroundColor = bg
        tv.nativeForegroundColor = useHomebrewTheme ? TerminalTheme.homebrewForeground : .white
        if useHomebrewTheme {
            tv.caretColor = TerminalTheme.homebrewForeground
        }
        tv.backgroundColor = bg
        tv.isOpaque = true
        tv.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.onTapped = { keyboardDismissed = false }
        tv.onPinch = { factor in
            let current = UserDefaults.standard.double(forKey: TerminalFontSettings.key)
            let base = current > 0 ? current : Double(TerminalFontSettings.defaultSize)
            let next = (base * Double(factor))
                .clamped(to: Double(TerminalFontSettings.minSize)...Double(TerminalFontSettings.maxSize))
            UserDefaults.standard.set(next, forKey: TerminalFontSettings.key)
        }
        context.coordinator.terminalView = tv
        onTerminalViewCreated(tv)
        return tv
    }

    func updateUIView(_ uiView: OdinTerminalView, context: Context) {
        if isConnected && !keyboardDismissed && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        }
        if abs(uiView.font.pointSize - fontSize) > 0.1 {
            uiView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDataSend: onDataSend, onSizeChanged: onSizeChanged)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
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
    private var pinchGesture: UIPinchGestureRecognizer?
    var onTapped: (() -> Void)?
    /// Called when the user pinches: passed the live scale factor (1.0 = no
    /// change). The host saves an updated font size to UserDefaults so it
    /// flows back through @AppStorage and resizes the terminal.
    var onPinch: ((CGFloat) -> Void)?

    /// Ensure standard keyboard every time focus is acquired
    override func becomeFirstResponder() -> Bool {
        inputView = nil
        return super.becomeFirstResponder()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard wheelGesture == nil, superview != nil else { return }
        inputView = nil
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(handleWheelPan(_:)))
        gesture.delegate = self
        wheelGesture = gesture
        addGestureRecognizer(gesture)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        pinchGesture = pinch
        addGestureRecognizer(pinch)
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

    /// Allow our wheel and pinch gestures to run simultaneously with SwiftTerm's gestures.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === wheelGesture || gestureRecognizer === pinchGesture
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        // `.ended` would fire with `gesture.scale` already reset to 1 by the
        // previous `.changed` event, so it's a no-op multiply — skip it.
        if gesture.state == .changed {
            onPinch?(gesture.scale)
            gesture.scale = 1
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        onTapped?()
        becomeFirstResponder()
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
                    // Swipe up → scroll down (natural scrolling)
                    sendWheelEvent(button: 65)
                    scrollAccumulator += pixelsPerScrollLine
                } else {
                    // Swipe down → scroll up (natural scrolling)
                    sendWheelEvent(button: 64)
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
    var fontSize: CGFloat = 12
    var isConnected: Bool
    @Binding var keyboardDismissed: Bool
    /// Opt-in `Homebrew` Terminal.app profile (phosphor-green text + caret).
    /// Default is `false` so existing call sites keep their white-on-black look.
    var useHomebrewTheme: Bool = false
    /// Override the terminal's canvas background. Defaults to black; set to
    /// e.g. `TerminalTheme.shellBackground` for the shell pane.
    var backgroundColorOverride: NSColor? = nil

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        tv.nativeBackgroundColor = backgroundColorOverride ?? .black
        tv.nativeForegroundColor = useHomebrewTheme ? TerminalTheme.homebrewForeground : .white
        if useHomebrewTheme {
            tv.caretColor = TerminalTheme.homebrewForeground
        }
        if let monoFont = NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.userFixedPitchFont(ofSize: fontSize) {
            tv.font = monoFont
        }
        context.coordinator.terminalView = tv
        onTerminalViewCreated(tv)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        if isConnected {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
        if abs(nsView.font.pointSize - fontSize) > 0.1,
           let monoFont = NSFont(name: nsView.font.fontName, size: fontSize)
            ?? NSFont(name: "Menlo", size: fontSize) {
            nsView.font = monoFont
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
        #if os(macOS)
        private var keyMonitor: Any?
        #endif

        init(onDataSend: @escaping (ArraySlice<UInt8>) -> Void,
             onSizeChanged: @escaping (Int, Int) -> Void) {
            self.onDataSend = onDataSend
            self.onSizeChanged = onSizeChanged
            super.init()
            #if os(macOS)
            installShiftReturnMonitor()
            #endif
        }

        #if os(macOS)
        deinit {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
        }

        /// Maps Shift+Return → ESC+CR (the byte sequence Option+Enter produces),
        /// which Claude Code's TUI treats as "insert newline" rather than
        /// "submit". A local key monitor pre-empts SwiftTerm's keyDown handling
        /// because `TerminalView.keyDown(with:)` is `public` (not `open`) and
        /// can't be overridden from outside the module. Scoped to "our own
        /// terminal view is firstResponder" so other panes / windows are
        /// unaffected.
        private func installShiftReturnMonitor() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let tv = self.terminalView,
                      event.window === tv.window,
                      event.window?.firstResponder === tv,
                      event.keyCode == 36,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
                else { return event }
                self.onDataSend(ArraySlice([0x1b, 0x0d]))
                return nil
            }
        }
        #endif

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

/// Shared color constants for terminal panes.
enum TerminalTheme {
    #if os(macOS)
    /// Bright phosphor green — macOS Terminal.app "Homebrew" profile foreground.
    static let homebrewForeground = NSColor(red: 40/255, green: 254/255, blue: 20/255, alpha: 1)
    /// Slightly-lifted dark grey for the shell pane so it reads as a distinct
    /// sub-pane under the (pure black) Claude session terminal.
    static let shellBackground = NSColor(red: 0x1E/255, green: 0x1E/255, blue: 0x1E/255, alpha: 1)
    #else
    static let homebrewForeground = UIColor(red: 40/255, green: 254/255, blue: 20/255, alpha: 1)
    static let shellBackground = UIColor(red: 0x1E/255, green: 0x1E/255, blue: 0x1E/255, alpha: 1)
    #endif
}
