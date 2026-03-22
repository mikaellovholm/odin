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
        tv.contentInsetAdjustmentBehavior = .never
        tv.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
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

/// Subclass to detect layout changes and update terminal grid size
class OdinTerminalView: TerminalView {
    private var lastAppliedSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        let newSize = bounds.size
        if newSize != lastAppliedSize && newSize.width > 0 && newSize.height > 0 {
            lastAppliedSize = newSize
        }
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
