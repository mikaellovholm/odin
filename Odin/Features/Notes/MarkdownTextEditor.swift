import SwiftUI

#if os(iOS)
import UIKit

/// Wraps UITextView so we can intercept Cmd+B / Cmd+I / Cmd+K and wrap the
/// current selection (or insert a paired marker at the cursor). SwiftUI's
/// TextEditor doesn't expose selection, so we drop down to UIKit.
struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> MarkdownUITextView {
        let view = MarkdownUITextView()
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .regular)
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.text = text
        return view
    }

    func updateUIView(_ uiView: MarkdownUITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        init(text: Binding<String>) { self._text = text }
        func textViewDidChange(_ textView: UITextView) { text = textView.text }
    }
}

final class MarkdownUITextView: UITextView {
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "b", modifierFlags: .command, action: #selector(toggleBold)),
            UIKeyCommand(input: "i", modifierFlags: .command, action: #selector(toggleItalic)),
            UIKeyCommand(input: "k", modifierFlags: .command, action: #selector(insertLink)),
        ]
    }

    @objc private func toggleBold() { wrapSelection(with: "**") }
    @objc private func toggleItalic() { wrapSelection(with: "*") }

    @objc private func insertLink() {
        guard let range = selectedTextRange else { return }
        let selected = text(in: range) ?? ""
        let template = selected.isEmpty
            ? "[link text](https://)"
            : "[\(selected)](https://)"
        replace(range, withText: template)
        if let newStart = position(from: range.start, offset: selected.isEmpty ? 1 : selected.count + 3),
           let cursor = textRange(from: newStart, to: newStart) {
            selectedTextRange = cursor
        }
        delegate?.textViewDidChange?(self)
    }

    private func wrapSelection(with marker: String) {
        guard let range = selectedTextRange else { return }
        let selected = text(in: range) ?? ""
        let wrapped = marker + selected + marker
        replace(range, withText: wrapped)
        if selected.isEmpty,
           let inner = position(from: range.start, offset: marker.count),
           let cursor = textRange(from: inner, to: inner) {
            selectedTextRange = cursor
        }
        delegate?.textViewDidChange?(self)
    }
}

#else
import AppKit

/// Wraps NSTextView so we can intercept Cmd+B / Cmd+I / Cmd+K and wrap the
/// current selection (or insert a paired marker at the cursor). SwiftUI's
/// TextEditor doesn't expose selection, so we drop down to AppKit.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let container = NSTextContainer(containerSize: containerSize)
        container.widthTracksTextView = true
        container.heightTracksTextView = false

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let tv = MarkdownNSTextView(frame: .zero, textContainer: container)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tv.isRichText = false
        tv.usesFontPanel = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.string = text

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? MarkdownNSTextView else { return }
        if tv.string != text {
            let prevRange = tv.selectedRange()
            tv.string = text
            let safeLoc = min(prevRange.location, tv.string.count)
            tv.setSelectedRange(NSRange(location: safeLoc, length: 0))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        init(text: Binding<String>) { self._text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text = tv.string
        }
    }
}

/// Subclass of NSTextView that intercepts Cmd+B / Cmd+I / Cmd+K. Used by
/// MarkdownTextEditor on macOS.
final class MarkdownNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.shift),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control),
              let chars = event.charactersIgnoringModifiers
        else { return super.performKeyEquivalent(with: event) }

        switch chars {
        case "b":
            wrapSelection(with: "**")
            return true
        case "i":
            wrapSelection(with: "*")
            return true
        case "k":
            insertLink()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func wrapSelection(with marker: String) {
        let range = selectedRange()
        let ns = (string as NSString).substring(with: range)
        let wrapped = marker + ns + marker
        if shouldChangeText(in: range, replacementString: wrapped) {
            replaceCharacters(in: range, with: wrapped)
            didChangeText()
            if ns.isEmpty {
                setSelectedRange(NSRange(location: range.location + marker.count, length: 0))
            }
        }
    }

    private func insertLink() {
        let range = selectedRange()
        let ns = (string as NSString).substring(with: range)
        let template = ns.isEmpty ? "[link text](https://)" : "[\(ns)](https://)"
        if shouldChangeText(in: range, replacementString: template) {
            replaceCharacters(in: range, with: template)
            didChangeText()
        }
    }
}
#endif
