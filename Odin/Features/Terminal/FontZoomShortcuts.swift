#if os(macOS)
import SwiftUI

/// Hidden buttons registering Cmd+= / Cmd+- / Cmd+0 to bump the persisted
/// terminal font size. Mount inside any view that should react to the
/// shortcuts (typically as `.background(FontZoomShortcuts())`).
struct FontZoomShortcuts: View {
    @AppStorage(TerminalFontSettings.key) private var fontSize: Double = Double(TerminalFontSettings.defaultSize)

    var body: some View {
        ZStack {
            Button("") { adjust(by: TerminalFontSettings.step) }
                .keyboardShortcut("=", modifiers: .command)
            Button("") { adjust(by: TerminalFontSettings.step) }
                .keyboardShortcut("+", modifiers: .command)
            Button("") { adjust(by: -TerminalFontSettings.step) }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { fontSize = Double(TerminalFontSettings.defaultSize) }
                .keyboardShortcut("0", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func adjust(by delta: CGFloat) {
        let next = (fontSize + Double(delta))
            .clamped(to: Double(TerminalFontSettings.minSize)...Double(TerminalFontSettings.maxSize))
        fontSize = next
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
#endif
