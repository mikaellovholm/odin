#if os(iOS)
import SwiftUI

/// Terminal-friendly key bar shown above the iOS soft keyboard. Subclassing
/// SwiftTerm's TerminalView to override `inputAccessoryView` doesn't work
/// because the property isn't open — so we render it in SwiftUI and overlay
/// it manually when the keyboard is visible.
struct TerminalAccessoryBar: View {
    var onSend: (ArraySlice<UInt8>) -> Void

    @State private var ctrlSticky: Bool = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key(label: "Esc") { send(bytes: [0x1B]) }
                key(label: "Tab") { send(bytes: [0x09]) }
                key(label: "Ctrl", highlighted: ctrlSticky) { ctrlSticky.toggle() }
                divider
                key(systemImage: "arrow.up") { sendEscape("[A") }
                key(systemImage: "arrow.down") { sendEscape("[B") }
                key(systemImage: "arrow.left") { sendEscape("[D") }
                key(systemImage: "arrow.right") { sendEscape("[C") }
                divider
                ForEach(["C", "D", "Z", "L", "R"], id: \.self) { letter in
                    key(label: "^\(letter)") { sendCtrl(letter) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.2))
            .frame(width: 1, height: 22)
    }

    private func key(label: String? = nil,
                     systemImage: String? = nil,
                     highlighted: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let label {
                    Text(label)
                        .font(.system(size: 15, weight: .medium))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(highlighted ? Color.blue.opacity(0.8) : Color.white.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
    }

    private func send(bytes: [UInt8]) {
        onSend(bytes[...])
    }

    private func sendEscape(_ tail: String) {
        var bytes: [UInt8] = [0x1B]
        bytes.append(contentsOf: Array(tail.utf8))
        onSend(bytes[...])
    }

    /// Send Ctrl+<letter> as the corresponding ASCII control byte (1..26).
    private func sendCtrl(_ letter: String) {
        guard let scalar = letter.uppercased().unicodeScalars.first,
              (65...90).contains(scalar.value) else { return }
        let byte = UInt8(scalar.value - 64)
        onSend([byte][...])
        if ctrlSticky { ctrlSticky = false }
    }
}
#endif
