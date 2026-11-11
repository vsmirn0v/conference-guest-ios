import AppKit
import CoreText
import SwiftUI

/// The NSTextView always contains the original Markdown. Preview changes attributes only.
struct MeetingNotesEditor: NSViewRepresentable {
    @ObservedObject var notes: MeetingNotesController
    let sessionID: UUID
    let editorID: UUID
    let formatted: Bool
    let command: NoteFormattingCommand?
    let commandID: UUID

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(coordinator: context.coordinator)
    }

    static func makeScrollView(coordinator: Coordinator, frame: NSRect = .zero) -> NSScrollView {
        let scrollView = NSScrollView(frame: frame)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        let textView = TextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        // The shared document owns history across AppKit editor lifetimes.
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.bounds.width, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = coordinator
        textView.notesCoordinator = coordinator
        scrollView.documentView = textView
        coordinator.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor final class TextView: NSTextView {
        weak var notesCoordinator: Coordinator?

        @objc(undo:) func undoNote(_ sender: Any?) { notesCoordinator?.performHistory(.undo) }
        @objc(redo:) func redoNote(_ sender: Any?) { notesCoordinator?.performHistory(.redo) }

        override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
            switch item.action {
            case #selector(undoNote(_:)): return notesCoordinator?.canPerformHistory(.undo) == true
            case #selector(redoNote(_:)): return notesCoordinator?.canPerformHistory(.redo) == true
            default: return super.validateUserInterfaceItem(item)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            notesCoordinator?.drawDecorations(in: dirtyRect)
        }

        override func unmarkText() {
            super.unmarkText()
            notesCoordinator?.commitUnmarkedText()
        }

        override func mouseDown(with event: NSEvent) {
            if notesCoordinator?.toggleChecklist(at: convert(event.locationInWindow, from: nil)) == true { return }
            super.mouseDown(with: event)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        private struct ViewportAnchor {
            let sourceIndex: Int
            let horizontalOffset: CGFloat
            let verticalOffset: CGFloat
        }

        private var parent: MeetingNotesEditor
        private weak var textView: TextView?
        private var source = ""
        private var generation = 0
        private var applying = false
        private var parseTask: Task<Void, Never>?
        private var parsed: [MeetingMarkdownPreview.Line] = []
        private var painted: [Int: MeetingMarkdownPreview.Line] = [:]
        private var active = NSRange()
        private var previewPending = false
        private var modePaintPending = false
        private var tableWidths: [Int: CGFloat] = [:]
#if DEBUG
        var onPreviewLayout: (() -> Void)?
#endif
        private var lastCommandID: UUID
        private var restoreState: MeetingNotesController.EditorState?
        private var selectionBeforeEdit: NSRange?
        private var selectionAfterEdit: NSRange?
        private var view: TextView? { textView }
        private var notes: MeetingNotesController { parent.notes }
        private var sessionID: UUID { parent.sessionID }
        private var editorID: UUID { parent.editorID }
        private var mayEdit: Bool { notes.editorOwner(sessionID: sessionID) == editorID }

        init(_ parent: MeetingNotesEditor) {
            self.parent = parent
            lastCommandID = parent.commandID
        }

        func attach(_ textView: TextView) {
            self.textView = textView
            textView.allowsUndo = false
            restoreState = notes.editorState(sessionID: sessionID)
            let notes = notes, editorID = editorID, sessionID = sessionID
            DispatchQueue.main.async { [weak self] in
                guard let self, view != nil else { return }
                notes.registerEditor(editorID, sessionID: sessionID, editor: .init(relinquish: { [weak self] in
                    guard let view = self?.view else { return true }
                    guard !view.hasMarkedText() else { return false }
                    view.isEditable = false
                    return true
                }, focus: { [weak self] in self?.focus() }, commitComposition: { [weak self] in
                    if self?.view?.hasMarkedText() == true { self?.view?.unmarkText() }
                    self?.commitUnmarkedText()
                }))
                if notes.editorOwner(sessionID: sessionID) == nil { notes.claimEditor(editorID, sessionID: sessionID) }
            }
            update(parent)
        }

        func detach() {
            parseTask?.cancel()
            if mayEdit, let view {
                if view.hasMarkedText() { view.unmarkText() }
                commitUnmarkedText()
                notes.setEditorState(sessionID: sessionID, selection: view.selectedRange(),
                                     scrollPoint: view.enclosingScrollView?.contentView.bounds.origin)
            }
            let notes = notes, editorID = editorID, sessionID = sessionID
            textView = nil
            DispatchQueue.main.async {
                notes.unregisterEditor(editorID, sessionID: sessionID)
                Task { await notes.flush(sessionID: sessionID) }
            }
        }

        private func focus() {
            guard let view, mayEdit else { return }
            update(parent)
            view.isEditable = true
            view.window?.deminiaturize(nil)
            view.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            view.window?.makeFirstResponder(view)
        }

        func update(_ parent: MeetingNotesEditor) {
            let modeChanged = self.parent.formatted != parent.formatted
            self.parent = parent
            guard let view else { return }
            view.isEditable = mayEdit
            if let draft = notes.draft(sessionID: sessionID), !view.hasMarkedText() {
                if !source.utf16.elementsEqual(draft.text.utf16) {
                    applying = true
                    let change = Self.edit(from: source, to: draft.text)
                    view.textStorage?.replaceCharacters(in: change.range, with: change.replacement)
                    movePainted(for: change.range, replacement: change.replacement)
                    source = draft.text
                    applying = false
                    schedulePreview()
                }
                generation = draft.generation
                if draft.savedText != nil, let state = restoreState {
                    let length = source.utf16.count
                    if let selection = state.selection {
                        let location = min(selection.location, length)
                        view.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
                    }
                    if let point = state.scrollPoint { view.enclosingScrollView?.contentView.scroll(to: point) }
                    restoreState = nil
                }
            }
            if modeChanged {
                modePaintPending = true
                applyRenderingMode()
            }
            if parent.commandID != lastCommandID {
                lastCommandID = parent.commandID
                if let command = parent.command, mayEdit, !view.hasMarkedText() {
                    let result = command.apply(to: source, selection: view.selectedRange())
                    let edit = Self.edit(from: source, to: result.text)
                    replaceText(in: edit.range, with: edit.replacement, selectionAfter: result.selection)
                    view.setSelectedRange(result.selection)
                }
            }
        }

        private func applyRenderingMode() {
            guard modePaintPending, let view, !view.hasMarkedText() else { return }
            modePaintPending = false
            let anchor = captureViewport()
            parseTask?.cancel()
            previewPending = false
            parsed = []
            paint(resetAll: true)
            if let anchor { restoreViewport(anchor) }
            if parent.formatted { schedulePreview(restoringViewport: anchor) }
        }

        private func captureViewport() -> ViewportAnchor? {
            guard let view, let scroll = view.enclosingScrollView, let manager = view.layoutManager,
                  let container = view.textContainer, manager.numberOfGlyphs > 0 else { return nil }
            let scrollPoint = scroll.contentView.bounds.origin
            let origin = view.textContainerOrigin
            let glyph = manager.glyphIndex(for: NSPoint(x: 0, y: max(0, scrollPoint.y - origin.y)), in: container)
            guard glyph < manager.numberOfGlyphs else { return nil }
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return ViewportAnchor(sourceIndex: manager.characterIndexForGlyph(at: glyph),
                horizontalOffset: scrollPoint.x, verticalOffset: scrollPoint.y - line.minY - origin.y)
        }

        private func restoreViewport(_ anchor: ViewportAnchor) {
            guard let view, let scroll = view.enclosingScrollView, let manager = view.layoutManager,
                  anchor.sourceIndex < (view.textStorage?.length ?? 0) else { return }
            let glyph = manager.glyphIndexForCharacter(at: anchor.sourceIndex)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let point = NSPoint(x: anchor.horizontalOffset, y: line.minY + view.textContainerOrigin.y + anchor.verticalOffset)
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func canPerformHistory(_ action: MeetingNotesController.HistoryAction) -> Bool {
            guard let view, !view.hasMarkedText() else { return false }
            return notes.canPerformHistory(action, sessionID: sessionID, editorID: editorID)
        }

        func performHistory(_ action: MeetingNotesController.HistoryAction) {
            guard let view, canPerformHistory(action) else { return }
            commitUnmarkedText()
            guard let selection = notes.performHistory(action, sessionID: sessionID, editorID: editorID) else { return }
            update(parent)
            let length = source.utf16.count
            let location = min(selection.location, length)
            let visible = NSRange(location: location, length: min(selection.length, length - location))
            view.setSelectedRange(visible)
            view.scrollRangeToVisible(visible)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            if !applying, selectionBeforeEdit == nil { selectionBeforeEdit = textView.selectedRange() }
            return true
        }

        func textDidChange(_ notification: Notification) { commitUnmarkedText() }

        func commitUnmarkedText() {
            guard !applying, let view, !view.hasMarkedText() else { return }
            defer { applyRenderingMode() }
            let before = selectionBeforeEdit
            let after = selectionAfterEdit
            selectionBeforeEdit = nil
            selectionAfterEdit = nil
            var updated = view.string
            updated.makeContiguousUTF8()
            guard !source.utf16.elementsEqual(updated.utf16) else { return }
            let change = Self.edit(from: source, to: updated)
            guard let next = notes.replace(sessionID: sessionID, editorID: editorID, generation: generation,
                                           range: change.range, with: change.replacement,
                                           selectionBefore: before, selectionAfter: after) else {
                // A responder may have queued a change just before its editing lease moved.
                source = updated
                update(parent)
                return
            }
            generation = next
            let incremental = canAdjustPreview(for: change.range, replacement: change.replacement)
            source = updated
            movePainted(for: change.range, replacement: change.replacement, preservingStyles: incremental)
            if modePaintPending { return }
            if incremental {
                parsed = painted.values.sorted { $0.range.location < $1.range.location }
                let line = (source as NSString).lineRange(for: NSRange(location: change.range.location, length: 0))
                paint(repainting: line.location)
#if DEBUG
                notifyPreviewLayout()
#endif
                schedulePreview(deferredValidation: true)
            } else {
                schedulePreview()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let view, !view.hasMarkedText(), source.utf16.elementsEqual(view.string.utf16) else { return }
            let range = (source as NSString).lineRange(for: view.selectedRange())
            if range != active, !previewPending { paint() }
        }

        func toggleChecklist(at point: NSPoint) -> Bool {
            guard parent.formatted, mayEdit, let view, !view.hasMarkedText(), let manager = view.layoutManager,
                  let container = view.textContainer else { return false }
            let local = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
            let glyph = manager.glyphIndex(for: local, in: container)
            guard glyph < manager.numberOfGlyphs,
                  manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return false }
            let index = manager.characterIndexForGlyph(at: glyph)
            guard let box = painted.values.first(where: { line in
                guard let mark = line.checklist else { return false }
                return NSLocationInRange(index, NSRange(location: mark.location - 1, length: 3))
            })?.checklist, NSMaxRange(box) <= source.utf16.count else { return false }
            let mark = (source as NSString).substring(with: box)
            replaceText(in: box, with: mark == " " ? "x" : " ")
            return true
        }

        private func replaceText(in range: NSRange, with replacement: String, selectionAfter: NSRange? = nil) {
            guard let view, view.shouldChangeText(in: range, replacementString: replacement) else { return }
            selectionAfterEdit = selectionAfter
            view.replaceCharacters(in: range, with: replacement)
            view.didChangeText()
        }

        /// A minimal UTF-16 replacement, widened to composed-character boundaries when needed.
        static func edit(from old: String, to new: String) -> (range: NSRange, replacement: String) {
            let lhs = Array(old.utf16), rhs = Array(new.utf16)
            var prefix = 0
            while prefix < min(lhs.count, rhs.count), lhs[prefix] == rhs[prefix] { prefix += 1 }
            if prefix == lhs.count, prefix == rhs.count { return (NSRange(location: prefix, length: 0), "") }
            var suffix = 0
            while suffix < min(lhs.count, rhs.count) - prefix,
                  lhs[lhs.count - suffix - 1] == rhs[rhs.count - suffix - 1] { suffix += 1 }
            let oldSource = old as NSString, newSource = new as NSString
            if prefix < lhs.count { prefix = min(prefix, oldSource.rangeOfComposedCharacterSequence(at: prefix).location) }
            if prefix < rhs.count { prefix = min(prefix, newSource.rangeOfComposedCharacterSequence(at: prefix).location) }
            if suffix > 0 {
                let oldEnd = lhs.count - suffix, newEnd = rhs.count - suffix
                let oldSequence = oldSource.rangeOfComposedCharacterSequence(at: oldEnd)
                let newSequence = newSource.rangeOfComposedCharacterSequence(at: newEnd)
                if oldSequence.location != oldEnd { suffix = min(suffix, lhs.count - oldSequence.upperBound) }
                if newSequence.location != newEnd { suffix = min(suffix, rhs.count - newSequence.upperBound) }
            }
            let range = NSRange(location: prefix, length: lhs.count - prefix - suffix)
            let replacement = newSource.substring(with: NSRange(location: prefix, length: rhs.count - prefix - suffix))
            return (range, replacement)
        }

        private func schedulePreview(deferredValidation: Bool = false, restoringViewport anchor: ViewportAnchor? = nil) {
            parseTask?.cancel()
            guard parent.formatted else { return }
            let source = source
            previewPending = !deferredValidation
            parseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(deferredValidation ? 240 : 16))
                guard !Task.isCancelled else { return }
                let worker = Task.detached(priority: .userInitiated) { MeetingMarkdownPreview.lines(in: source) }
                let lines = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, self.view?.hasMarkedText() == false else { return }
                self.previewPending = false
                self.parsed = lines
                self.paint()
                if let anchor { self.restoreViewport(anchor) }
#if DEBUG
                if !deferredValidation { self.notifyPreviewLayout() }
#endif
            }
        }

#if DEBUG
        private func notifyPreviewLayout() {
            guard let onPreviewLayout, let view, let manager = view.layoutManager,
                  let container = view.textContainer else { return }
            let origin = view.textContainerOrigin
            manager.ensureLayout(forBoundingRect: view.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
            onPreviewLayout()
        }
#endif

        /// A word-internal edit cannot create or remove a Markdown delimiter.
        /// Adjust current presentation ranges immediately, and validate with the
        /// full parser after typing pauses. Syntax edits always use the full parser.
        private func canAdjustPreview(for change: NSRange, replacement: String) -> Bool {
            guard parent.formatted, !previewPending, change.location > 0 else { return false }
            let text = source as NSString
            let line = text.lineRange(for: NSRange(location: change.location, length: 0))
            guard change.location > line.location, change.upperBound <= line.upperBound,
                  let previous = UnicodeScalar(text.character(at: change.location - 1)),
                  CharacterSet.letters.contains(previous),
                  replacement.unicodeScalars.allSatisfy(CharacterSet.letters.contains),
                  text.substring(with: change).unicodeScalars.allSatisfy(CharacterSet.letters.contains) else { return false }
            // Reference definitions, automatic links, tables and checklist
            // markup can affect other spans even for a word-internal edit.
            let contextualSyntax = CharacterSet(charactersIn: "[]<>\\|:@\t")
            return text.rangeOfCharacter(from: contextualSyntax, options: [], range: line).location == NSNotFound
        }

        private func movePainted(for change: NSRange, replacement: String, preservingStyles: Bool = false) {
            let delta = replacement.utf16.count - change.length
            var moved: [Int: MeetingMarkdownPreview.Line] = [:]
            moved.reserveCapacity(painted.count)
            for var line in painted.values {
                if line.range.location >= change.upperBound, line.range.location != change.location {
                    line.range.location += delta
                    line.spans = line.spans.map { span in
                        var span = span
                        span.range.location += delta
                        return span
                    }
                    if line.checklist != nil { line.checklist?.location += delta }
                    line.tableRow?.shift(by: delta)
                } else if line.range.upperBound > change.location {
                    line.range.length = max(0, line.range.length + delta)
                    if preservingStyles {
                        line.spans = line.spans.map { span in
                            var span = span
                            if span.range.location >= change.upperBound {
                                span.range.location += delta
                            } else if span.range.upperBound >= change.upperBound {
                                span.range.length = max(0, span.range.length + delta)
                            }
                            return span
                        }
                    } else {
                        line.spans = []
                        line.checklist = nil
                        line.tableRow = nil
                    }
                }
                moved[line.range.location] = line
            }
            painted = moved
            parsed = []
        }

        private func paint(resetAll: Bool = false, repainting location: Int? = nil) {
            guard let view, let storage = view.textStorage, !view.hasMarkedText() else { return }
            let previousActive = active
            active = (source as NSString).lineRange(for: view.selectedRange())
            let old = painted
            painted = Dictionary(uniqueKeysWithValues: parsed.map { ($0.range.location, $0) })
            var changed = Set(old.keys).union(painted.keys).filter { key in
                if key == location || old[key] != painted[key] { return true }
                guard let line = painted[key] else { return false }
                return intersects(line.range, active) != intersects(line.range, previousActive)
            }
            guard resetAll || !changed.isEmpty || storage.length > 0 && storage.attribute(.font, at: 0, effectiveRange: nil) == nil else { return }
            let tableGroups = Set(changed.flatMap { key in [old[key]?.tableGroup, painted[key]?.tableGroup].compactMap { $0 } })
            let rows = Dictionary(grouping: painted.values.filter {
                $0.tableRow != nil && $0.tableGroup.map(tableGroups.contains) == true
            }) { $0.tableGroup }
            changed.formUnion(rows.values.flatMap { $0.map(\.range.location) })
            applying = true
            storage.beginEditing()
            let base = Self.attributes(formatted: parent.formatted)
            if storage.length > 0, resetAll || storage.attribute(.font, at: 0, effectiveRange: nil) == nil {
                storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
            }
            for key in changed {
                if let oldLine = old[key] { reset(oldLine.range, in: storage, with: base) }
            }
            for key in changed {
                if let line = painted[key] {
                    reset(line.range, in: storage, with: base)
                    decorate(line, in: storage, revealing: intersects(line.range, active))
                }
            }
            for group in tableGroups {
                tableWidths[group] = rows[group].map { alignTableRows($0, in: storage) }
            }
            storage.endEditing()
            view.typingAttributes = base
            view.needsDisplay = true
            applying = false
        }

        private func reset(_ range: NSRange, in storage: NSTextStorage, with attributes: [NSAttributedString.Key: Any]) {
            guard range.location < storage.length else { return }
            let clamped = NSRange(location: range.location, length: min(range.length, storage.length - range.location))
            storage.setAttributes(attributes, range: clamped)
        }

        private static func attributes(formatted: Bool) -> [NSAttributedString.Key: Any] {
            [.font: formatted ? NSFont.systemFont(ofSize: 14) : NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
             .foregroundColor: NSColor.labelColor]
        }

        private func decorate(_ line: MeetingMarkdownPreview.Line, in storage: NSTextStorage, revealing: Bool) {
            guard NSMaxRange(line.range) <= storage.length else { return }
            if let level = line.heading {
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: CGFloat(max(15, 26 - level * 2)), weight: .semibold), range: line.range)
            }
            if line.quote { storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line.range) }
            if line.code || line.table {
                storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: line.tableHeader ? .semibold : .regular),
                                       .backgroundColor: NSColor.controlBackgroundColor], range: line.range)
            }
            if line.rule || line.tableDelimiter {
                storage.addAttributes([.foregroundColor: revealing ? NSColor.secondaryLabelColor : NSColor.clear,
                                       .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)], range: line.range)
            }
            for span in line.spans where span.range.length > 0 && NSMaxRange(span.range) <= storage.length {
                let range = span.range
                let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 14)
                switch span.style {
                case .bold, .italic:
                    let trait: NSFontTraitMask = span.style == .bold ? .boldFontMask : .italicFontMask
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: range)
                case .strike: storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                case .code:
                    storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                           .backgroundColor: NSColor.controlBackgroundColor], range: range)
                case .link:
                    storage.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
                case .syntax:
                    storage.addAttribute(.foregroundColor, value: revealing ? NSColor.secondaryLabelColor : NSColor.clear, range: range)
                    if !revealing { storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.1), range: range) }
                case .listMarker:
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                case .checked, .unchecked:
                    storage.addAttributes([.foregroundColor: revealing ? NSColor.controlAccentColor : NSColor.clear,
                                           .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)], range: range)
                }
            }
        }

        /// Use shaped text advances, including font traits, fallback glyphs, and the
        /// hidden width of Markdown syntax. Each divider remains a source pipe.
        private func alignTableRows(_ lines: [MeetingMarkdownPreview.Line], in storage: NSTextStorage) -> CGFloat {
            let pipeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let pipeWidth = ("|" as NSString).size(withAttributes: [.font: pipeFont]).width
            var maxWidths: [Int: CGFloat] = [:]
            var measuredRows: [(row: MeetingMarkdownPreview.TableRow, line: NSRange, widths: [CGFloat])] = []
            for line in lines {
                guard let row = line.tableRow, line.range.upperBound <= storage.length else { continue }
                let content = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: line.range))
                if intersects(line.range, active) {
                    for syntax in line.spans where syntax.style == .syntax && NSIntersectionRange(syntax.range, line.range) == syntax.range {
                        let range = NSRange(location: syntax.range.location - line.range.location, length: syntax.range.length)
                        content.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.1), range: range)
                    }
                }
                let widths = row.cells.enumerated().map { column, cell -> CGFloat in
                    let range = NSRange(location: cell.range.location - line.range.location, length: cell.range.length)
                    let shaped = CTLineCreateWithAttributedString(content.attributedSubstring(from: range))
                    let width = CGFloat(CTLineGetTypographicBounds(shaped, nil, nil, nil))
                    maxWidths[column] = max(width, maxWidths[column] ?? 0)
                    return width
                }
                measuredRows.append((row, line.range, widths))
            }
            let hasLeadingPipe = measuredRows.contains { $0.row.leadingPipe != nil }
            for measured in measuredRows where !intersects(measured.line, active) {
                if let pipe = measured.row.leadingPipe {
                    storage.addAttributes([.foregroundColor: NSColor.clear, .font: pipeFont],
                        range: NSRange(location: pipe, length: 1))
                } else if hasLeadingPipe {
                    let indent = NSMutableParagraphStyle()
                    indent.firstLineHeadIndent = pipeWidth
                    indent.headIndent = pipeWidth
                    storage.addAttribute(.paragraphStyle, value: indent, range: measured.line)
                }
                for (column, cell) in measured.row.cells.enumerated() {
                    guard let pipe = cell.trailingPipe else { continue }
                    let padding = max(0, (maxWidths[column] ?? 0) - measured.widths[column])
                    storage.addAttributes([.foregroundColor: NSColor.clear, .font: pipeFont, .kern: padding],
                        range: NSRange(location: pipe, length: 1))
                }
            }
            return maxWidths.values.reduce(0, +) + pipeWidth * CGFloat(maxWidths.count + (hasLeadingPipe ? 1 : 0))
        }

        func drawDecorations(in dirtyRect: NSRect) {
            guard parent.formatted, !previewPending, let view, let manager = view.layoutManager,
                  let container = view.textContainer else { return }
            let origin = view.textContainerOrigin
            let visible = manager.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
            let characters = manager.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
            for line in painted.values where intersects(line.range, characters) && !intersects(line.range, active) {
                guard NSMaxRange(line.range) <= (view.textStorage?.length ?? 0) else { continue }
                let glyphs = manager.glyphRange(forCharacterRange: line.range, actualCharacterRange: nil)
                guard glyphs.length > 0 else { continue }
                let fragment = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                    .offsetBy(dx: origin.x, dy: origin.y)
                if line.rule || line.tableDelimiter {
                    let tableRight = fragment.minX + 5 + (line.tableGroup.flatMap { tableWidths[$0] } ?? 0)
                    let right = line.rule ? fragment.maxX - 8 : min(fragment.maxX - 8, tableRight)
                    stroke(from: NSPoint(x: fragment.minX + 5, y: fragment.midY),
                           to: NSPoint(x: right, y: fragment.midY))
                }
                for pipe in line.tableRow?.dividerIndices ?? [] {
                    let glyphRange = manager.glyphRange(forCharacterRange: NSRange(location: pipe, length: 1),
                                                        actualCharacterRange: nil)
                    guard glyphRange.length > 0 else { continue }
                    let rect = manager.boundingRect(forGlyphRange: glyphRange, in: container)
                        .offsetBy(dx: origin.x, dy: origin.y)
                    stroke(from: NSPoint(x: rect.maxX - 3, y: rect.minY), to: NSPoint(x: rect.maxX - 3, y: rect.maxY))
                }
                if let span = line.spans.first(where: { $0.style == .checked || $0.style == .unchecked }) {
                    let box = manager.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
                    let rect = manager.boundingRect(forGlyphRange: box, in: container)
                        .offsetBy(dx: origin.x, dy: origin.y)
                    let symbol = span.style == .checked ? "☑" : "☐"
                    (symbol as NSString).draw(at: NSPoint(x: rect.minX + 3, y: rect.minY), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.controlAccentColor
                    ])
                }
            }
        }

        private func stroke(from start: NSPoint, to end: NSPoint) {
            let line = NSBezierPath()
            line.move(to: start)
            line.line(to: end)
            line.lineWidth = 1
            NSColor.separatorColor.setStroke()
            line.stroke()
        }

        private func intersects(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
            rhs.length == 0 ? NSLocationInRange(rhs.location, lhs) : NSIntersectionRange(lhs, rhs).length > 0
        }
    }
}
