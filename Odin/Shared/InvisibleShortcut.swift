#if os(macOS)
import SwiftUI

/// Hidden zero-frame button that registers a `keyboardShortcut`. Used to wire
/// shortcuts (⌘1…⌘9, ⇧⌘P/T/D/R, etc.) when the corresponding action lives in
/// a view that doesn't expose a toolbar / menu hook — SwiftUI keeps the
/// shortcut active even though the button itself doesn't render. Stacked in a
/// `ZStack` for each shortcut you want to register, then placed inside a
/// `.background(...)` so they never affect layout.
struct InvisibleShortcut: View {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let action: () -> Void

    init(
        _ key: KeyEquivalent,
        modifiers: EventModifiers = .command,
        action: @escaping () -> Void
    ) {
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
    }
}

extension View {
    /// Wraps a collection of `InvisibleShortcut`s in a zero-frame, hit-test-
    /// disabled `ZStack` so the parent can drop the result into a
    /// `.background(...)` without affecting layout. Lets callers express
    /// `keyboardShortcuts { InvisibleShortcut(...); InvisibleShortcut(...) }`
    /// instead of repeating the ZStack + opacity + allowsHitTesting boilerplate.
    @ViewBuilder
    func invisibleShortcutsContainer() -> some View {
        self
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
    }
}
#endif
