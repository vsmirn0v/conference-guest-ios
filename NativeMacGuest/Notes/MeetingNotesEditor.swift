import AppKit
import SwiftUI

/// Raw Markdown editor around `NSTextView`. The raw string is canonical: this view
/// never parses or normalizes the note. Live transcription updates and export
/// activity never touch this view, so typing is never interrupted.
struct MeetingNotesEditor: NSViewRepresentable {
    let text: String
    let onChange: (String) -> Void
    /// Current selection, reported for formatting commands.
    var onSelectionChange: ((NSRange) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let textView = NSTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.bounds.width, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            // Hydration or a newer committed revision replaced the buffer. Preserve the
            // undo history only for user typing; wholesale replacement starts fresh.
            context.coordinator.applyingExternal = true
            textView.string = text
            context.coordinator.applyingExternal = false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let representable: MeetingNotesEditor
        var applyingExternal = false
        init(_ representable: MeetingNotesEditor) { self.representable = representable }

        func textDidChange(_ notification: Notification) {
            guard !applyingExternal, let textView = notification.object as? NSTextView else { return }
            representable.onChange(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applyingExternal, let textView = notification.object as? NSTextView else { return }
            representable.onSelectionChange?(textView.selectedRange())
        }
    }
}
