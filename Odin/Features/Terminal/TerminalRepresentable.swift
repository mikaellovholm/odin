import SwiftUI
import SwiftTerm

#if os(iOS)
struct TerminalRepresentable: UIViewRepresentable {
    var onTerminalViewCreated: (TerminalView) -> Void
    var onDataSend: (ArraySlice<UInt8>) -> Void
    var onSizeChanged: (Int, Int) -> Void

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        onTerminalViewCreated(tv)
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDataSend: onDataSend, onSizeChanged: onSizeChanged)
    }
}
#else
struct TerminalRepresentable: NSViewRepresentable {
    var onTerminalViewCreated: (TerminalView) -> Void
    var onDataSend: (ArraySlice<UInt8>) -> Void
    var onSizeChanged: (Int, Int) -> Void

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.terminalDelegate = context.coordinator
        onTerminalViewCreated(tv)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDataSend: onDataSend, onSizeChanged: onSizeChanged)
    }
}
#endif

extension TerminalRepresentable {
    class Coordinator: NSObject, TerminalViewDelegate {
        let onDataSend: (ArraySlice<UInt8>) -> Void
        let onSizeChanged: (Int, Int) -> Void

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
