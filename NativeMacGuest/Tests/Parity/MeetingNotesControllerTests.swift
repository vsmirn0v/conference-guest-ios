import AppKit
import Foundation
import XCTest
@testable import RockNativeDesktop

/// Debounced note commits: hydration, flush, generation fencing and error surfaces.
@MainActor final class MeetingNotesControllerTests: XCTestCase {
    private var temp: URL!
    private var library: MeetingLibraryController!
    private var notes: MeetingNotesController!

    override func setUp() async throws {
        try await super.setUp()
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-notes-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        library = MeetingLibraryController(root: temp)
        notes = MeetingNotesController(library: library)
        await library.prepare()
        XCTAssertTrue(library.isReady)
    }

    override func tearDown() async throws {
        await library?.close()
        library = nil
        notes = nil
        try? FileManager.default.removeItem(at: temp)
        try await super.tearDown()
    }

    private func makeSession(_ id: UUID = UUID(), title: String = "Notes Test") async -> UUID {
        _ = await library.createSession(id: id, title: title, invitation: nil, roomIdentity: "", calendarSeriesID: nil)
        return id
    }

    func testFlushCommitsLatestDraft() async {
        let id = await makeSession()
        notes.update(sessionID: id, text: "draft one")
        notes.update(sessionID: id, text: "draft two")
        let committed = await notes.flush(sessionID: id)
        XCTAssertTrue(committed)
        let record = await library.note(sessionID: id)
        XCTAssertEqual(record?.markdown, "draft two")
        XCTAssertEqual(notes.draft(sessionID: id)?.savedText, "draft two")
        XCTAssertNil(notes.draft(sessionID: id)?.saveError)
    }

    func testHydrateAdoptsCommittedNoteWithoutDirtying() async {
        let id = await makeSession()
        _ = await library.saveNote(sessionID: id, markdown: "already saved")
        notes.hydrate(sessionID: id, text: "already saved")
        // A hydrated buffer that matches the committed text is not dirty; flushing is a no-op success.
        let committed = await notes.flush(sessionID: id)
        XCTAssertTrue(committed)
        XCTAssertEqual(notes.buffer(sessionID: id), "already saved")
    }

    func testFlushForUnknownSessionReportsFailure() async {
        let unknown = UUID()
        notes.update(sessionID: unknown, text: "orphan")
        let committed = await notes.flush(sessionID: unknown)
        XCTAssertFalse(committed)
        XCTAssertNotNil(notes.draft(sessionID: unknown)?.saveError)
    }

    func testGenerationFencePreventsStaleCommitFromMarkingSaved() async {
        let id = await makeSession()
        notes.update(sessionID: id, text: "first")
        // Simulate a slow commit for generation 1 racing a newer edit:
        // commit the current text directly, then mark generation 2.
        _ = await notes.flush(sessionID: id)
        notes.update(sessionID: id, text: "second")
        // A stale completion for generation 1 must not mark generation 2 saved.
        XCTAssertNotEqual(notes.draft(sessionID: id)?.savedText, "second")
        XCTAssertEqual(notes.buffer(sessionID: id), "second")
        let committed = await notes.flush(sessionID: id)
        XCTAssertTrue(committed)
        XCTAssertEqual(notes.draft(sessionID: id)?.savedText, "second")
        let record = await library.note(sessionID: id)
        XCTAssertEqual(record?.markdown, "second")
    }

    func testContinuousTypingCommitsWithoutFirstPause() async {
        let id = await makeSession()
        for index in 0..<8 {
            notes.update(sessionID: id, text: "Edit \(index)")
            try? await Task.sleep(for: .milliseconds(150))
        }
        let record = await library.note(sessionID: id)
        XCTAssertNotNil(record)
        XCTAssertNotEqual(record?.markdown, "Edit 7")
        let flushed = await notes.flush(sessionID: id)
        XCTAssertTrue(flushed)
        let final = await library.note(sessionID: id)
        XCTAssertEqual(final?.markdown, "Edit 7")
    }

    func testLeaseAndGenerationRejectStaleRangeEdits() async throws {
        let session = await makeSession()
        let first = UUID(), second = UUID()
        await notes.load(sessionID: session)
        XCTAssertTrue(notes.claimEditor(first, sessionID: session))
        XCTAssertEqual(notes.replace(sessionID: session, editorID: first, generation: 0,
                                     range: NSRange(location: 0, length: 0), with: "😀 café"), 1)
        notes.registerEditor(first, sessionID: session, editor: .init(relinquish: { false }, focus: {}))
        XCTAssertFalse(notes.claimEditor(second, sessionID: session))
        notes.registerEditor(first, sessionID: session, editor: .init(relinquish: { true }, focus: {}))
        XCTAssertTrue(notes.claimEditor(second, sessionID: session))
        XCTAssertNil(notes.replace(sessionID: session, editorID: first, generation: 1,
                                   range: NSRange(location: 0, length: 2), with: "lost"))
        XCTAssertNil(notes.replace(sessionID: session, editorID: second, generation: 0,
                                   range: NSRange(location: 0, length: 2), with: "stale"))
        XCTAssertEqual(notes.replace(sessionID: session, editorID: second, generation: 1,
                                     range: NSRange(location: 0, length: 2), with: "🕴️"), 2)
        XCTAssertEqual(notes.buffer(sessionID: session), "🕴️ café")
    }

    func testFlushAllCommitsMarkedAppKitInput() async throws {
        let session = await makeSession()
        let editor = UUID()
        await notes.load(sessionID: session)
        let representable = MeetingNotesEditor(notes: notes, sessionID: session, editorID: editor,
            formatted: true, command: nil, commandID: UUID())
        let coordinator = MeetingNotesEditor.Coordinator(representable)
        let view = MeetingNotesEditor.TextView(frame: NSRect(x: 0, y: 0, width: 300, height: 220))
        view.delegate = coordinator
        view.notesCoordinator = coordinator
        coordinator.attach(view)
        defer { coordinator.detach() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(notes.claimEditor(editor, sessionID: session))
        coordinator.update(representable)
        view.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        let failed = await notes.flushAll()
        XCTAssertTrue(failed.isEmpty)
        XCTAssertFalse(view.hasMarkedText())
        let saved = await library.note(sessionID: session)
        XCTAssertEqual(saved?.markdown, "日本語")
    }

#if DEBUG
    func testHundredKiBTypingToTextKitLayout() async throws {
        let session = await makeSession()
        let editor = UUID()
        let block = """
        # **Planning** and *café*
        > Review the draft before the next round.

        | Topic | Owner |
        | --- | --- |
        | Follow-up | 😀 |

        - [x] Review notes
        - [ ] Update the checklist
        - ~~Replace~~ Add [reference](https://example.invalid/notes).

        ---

        ```swift
        // **Literal Markdown** inside the code block.
        ```


        """
        let maxBytes = 100 * 1024
        let initial = String(repeating: block, count: (maxBytes - 32) / block.utf8.count)
        notes.hydrate(sessionID: session, text: initial)
        let representable = MeetingNotesEditor(notes: notes, sessionID: session, editorID: editor,
            formatted: true, command: nil, commandID: UUID())
        let coordinator = MeetingNotesEditor.Coordinator(representable)
        let view = MeetingNotesEditor.TextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.delegate = coordinator
        view.notesCoordinator = coordinator
        defer { coordinator.detach() }
        let firstLayout = expectation(description: "initial TextKit layout")
        let firstStart = DispatchTime.now().uptimeNanoseconds
        var firstOpenMS = 0.0
        coordinator.onPreviewLayout = {
            firstOpenMS = Double(DispatchTime.now().uptimeNanoseconds - firstStart) / 1_000_000
            firstLayout.fulfill()
        }
        coordinator.attach(view)
        await fulfillment(of: [firstLayout], timeout: 5)
        XCTAssertTrue(notes.claimEditor(editor, sessionID: session))
        coordinator.update(representable)

        var samples: [Double] = []
        for index in 0..<32 {
            let layout = expectation(description: "TextKit layout after edit \(index + 1)")
            let start = DispatchTime.now().uptimeNanoseconds
            coordinator.onPreviewLayout = {
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                layout.fulfill()
            }
            view.insertText("a", replacementRange: NSRange(location: 7, length: 0))
            await fulfillment(of: [layout], timeout: 5)
        }
        coordinator.onPreviewLayout = nil
        XCTAssertEqual(samples.count, 32)
        guard !samples.isEmpty else { return }
        let p95 = samples.sorted()[Int(ceil(Double(samples.count) * 0.95)) - 1]
        print("Notes layout benchmark: \(initial.utf8.count) bytes, \(samples.count) edits, first open \(firstOpenMS) ms, typing p95 \(p95) ms")
        XCTAssertTrue(notes.buffer(sessionID: session).hasPrefix("# **Pla" + String(repeating: "a", count: 32)))
    }
#endif

#if DEBUG
    func testNativePasteAlignsShapedTableColumnsAndKeepsFencedCodeAndCaret() async throws {
        let session = await makeSession()
        let editor = UUID()
        await notes.load(sessionID: session)
        let preview = MeetingNotesEditor(notes: notes, sessionID: session, editorID: editor,
            formatted: true, command: nil, commandID: UUID())
        let coordinator = preview.makeCoordinator()
        let scroll = MeetingNotesEditor.makeScrollView(coordinator: coordinator,
            frame: NSRect(x: 0, y: 0, width: 1400, height: 450))
        let view = try XCTUnwrap(scroll.documentView as? MeetingNotesEditor.TextView)
        defer { coordinator.detach() }
        XCTAssertTrue(notes.claimEditor(editor, sessionID: session))
        coordinator.update(preview)

        let fixture = #"""
        | **Title** | Other |
        | --- | --- |
        | A very long column that is substantially wider than 32 characters | `Code` |
        | **漢字** 😀 👩‍💻 and \| literal | [Link](https://example.invalid) |

        ```markdown
        **Do not format this as emphasis**
        ```

        Caret after pasted content
        """#
        let pasteboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(pasteboard.setString(fixture, forType: .string))
        let formatted = expectation(description: "native paste reaches formatted layout")
        var layoutMS: Double?
        let start = DispatchTime.now().uptimeNanoseconds
        coordinator.onPreviewLayout = {
            layoutMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            formatted.fulfill()
        }
        XCTAssertTrue(view.readSelection(from: pasteboard, type: .string))
        await fulfillment(of: [formatted], timeout: 5)
        coordinator.onPreviewLayout = nil
        let caret = NSRange(location: fixture.utf16.count, length: 0)
        XCTAssertEqual(view.selectedRange(), caret)
        XCTAssertEqual(view.string, fixture)
        XCTAssertEqual(notes.buffer(sessionID: session), fixture)

        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        manager.ensureLayout(for: container)
        let rows = MeetingMarkdownPreview.lines(in: fixture).compactMap(\.tableRow)
        XCTAssertEqual(rows.count, 3)
        let dividers = rows.map { row in
            row.dividerIndices.map { pipe in
                let glyph = manager.glyphRange(forCharacterRange: NSRange(location: pipe, length: 1), actualCharacterRange: nil)
                return manager.boundingRect(forGlyphRange: glyph, in: container).maxX
            }
        }
        for row in dividers.dropFirst() {
            XCTAssertEqual(row.count, dividers.first?.count)
            for (x, expected) in zip(row, dividers.first ?? []) {
                XCTAssertEqual(x, expected, accuracy: 1.5)
            }
        }
        XCTAssertGreaterThan(dividers.first?.dropFirst().first ?? 0, 320, "long column should exceed the old character cap")
        let code = (fixture as NSString).range(of: "Do not format")
        let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertTrue(NSApp.sendAction(#selector(MeetingNotesEditor.TextView.undoNote(_:)), to: view, from: nil))
        XCTAssertEqual(view.string, "")
        XCTAssertTrue(NSApp.sendAction(#selector(MeetingNotesEditor.TextView.redoNote(_:)), to: view, from: nil))
        XCTAssertEqual(view.string, fixture)
        XCTAssertEqual(view.selectedRange(), caret)
        let saved = await notes.flush(sessionID: session)
        XCTAssertTrue(saved)
        let reloaded = await library.note(sessionID: session)
        XCTAssertEqual(reloaded?.markdown, fixture)
        print("Notes native Markdown paste: \(fixture.utf8.count) bytes, visible TextKit layout \(layoutMS ?? 0) ms")
    }

    func testModeSwitchKeepsScrolledSourceLineAndArbitrarySelection() async throws {
        let session = await makeSession()
        let editor = UUID()
        let text = (0..<90).map { "# Heading \($0)\n\nBody with **bold** text.\n\n" }.joined()
        notes.hydrate(sessionID: session, text: text)
        let formatted = MeetingNotesEditor(notes: notes, sessionID: session, editorID: editor,
            formatted: true, command: nil, commandID: UUID())
        let source = MeetingNotesEditor(notes: notes, sessionID: session, editorID: editor,
            formatted: false, command: nil, commandID: UUID())
        let coordinator = formatted.makeCoordinator()
        let initial = expectation(description: "initial formatted preview")
        coordinator.onPreviewLayout = { initial.fulfill() }
        let scroll = MeetingNotesEditor.makeScrollView(coordinator: coordinator,
            frame: NSRect(x: 0, y: 0, width: 520, height: 250))
        let view = try XCTUnwrap(scroll.documentView as? MeetingNotesEditor.TextView)
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        defer { coordinator.detach() }
        XCTAssertTrue(notes.claimEditor(editor, sessionID: session))
        coordinator.update(formatted)
        await fulfillment(of: [initial], timeout: 5)
        coordinator.onPreviewLayout = nil

        func sourceAtTop() -> Int {
            let y = max(0, scroll.contentView.bounds.minY - view.textContainerOrigin.y + 2)
            let glyph = manager.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
            return manager.characterIndexForGlyph(at: glyph)
        }

        let selected = (text as NSString).range(of: "Heading 41")
        let top = (text as NSString).range(of: "# Heading 36")
        view.setSelectedRange(selected)
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: top.location)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: line.minY + view.textContainerOrigin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(sourceAtTop(), top.location)
        coordinator.update(source)
        XCTAssertEqual(view.selectedRange(), selected)
        XCTAssertEqual(sourceAtTop(), top.location)

        let restored = expectation(description: "formatted preview restores the same viewport")
        coordinator.onPreviewLayout = { restored.fulfill() }
        coordinator.update(formatted)
        await fulfillment(of: [restored], timeout: 5)
        coordinator.onPreviewLayout = nil
        XCTAssertEqual(view.selectedRange(), selected)
        XCTAssertEqual(sourceAtTop(), top.location)
        XCTAssertEqual(view.string, text)
    }

    func testRenderingModeSwitchWaitsForMarkedComposition() async throws {
        let session = await makeSession()
        let editor = UUID()
        let text = "# **Existing**\n\n"
        notes.hydrate(sessionID: session, text: text)
        let preview = MeetingNotesEditor(notes: notes, sessionID: session, editorID: editor,
            formatted: true, command: nil, commandID: UUID())
        let source = MeetingNotesEditor(notes: notes, sessionID: session, editorID: editor,
            formatted: false, command: nil, commandID: UUID())
        let coordinator = preview.makeCoordinator()
        let ready = expectation(description: "preview visible before composition")
        coordinator.onPreviewLayout = { ready.fulfill() }
        let scroll = MeetingNotesEditor.makeScrollView(coordinator: coordinator,
            frame: NSRect(x: 0, y: 0, width: 550, height: 250))
        let view = try XCTUnwrap(scroll.documentView as? MeetingNotesEditor.TextView)
        defer { coordinator.detach() }
        XCTAssertTrue(notes.claimEditor(editor, sessionID: session))
        coordinator.update(preview)
        await fulfillment(of: [ready], timeout: 5)
        coordinator.onPreviewLayout = nil
        let position = text.utf16.count
        view.setSelectedRange(NSRange(location: position, length: 0))
        view.setMarkedText("日本語", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: position, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        let marked = view.markedRange()
        let composingSelection = view.selectedRange()
        coordinator.update(source)
        XCTAssertEqual(view.markedRange(), marked)
        XCTAssertEqual(view.selectedRange(), composingSelection)
        XCTAssertEqual(notes.buffer(sessionID: session), text)

        let baseline = NSTextView(frame: view.frame)
        baseline.string = text
        baseline.setSelectedRange(NSRange(location: position, length: 0))
        baseline.setMarkedText("日本語", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: position, length: 0))
        baseline.unmarkText()

        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.string, text + "日本語")
        XCTAssertEqual(notes.buffer(sessionID: session), text + "日本語")
        XCTAssertEqual(view.selectedRange(), baseline.selectedRange())
        let font = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font, NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        let saved = await notes.flush(sessionID: session)
        XCTAssertTrue(saved)
        let reloaded = await library.note(sessionID: session)
        XCTAssertEqual(reloaded?.markdown, text + "日本語")
    }
#endif

    func testDetachedWindowsReuseSessionAndCloseWithIndependentDrafts() async throws {
        let firstID = await makeSession(title: "Window One")
        let secondID = await makeSession(title: "Window Two")
        let windows = MeetingNotesWindows(notes: notes, persistsFrames: false)
        let first = try XCTUnwrap(windows.open(sessionID: firstID, title: "Window One", date: nil, showInMain: {}))
        let same = try XCTUnwrap(windows.open(sessionID: firstID, title: "Window One", date: nil, showInMain: {}))
        let second = try XCTUnwrap(windows.open(sessionID: secondID, title: "Window Two", date: nil, showInMain: {}))
        defer {
            if first.isVisible { first.close() }
            if second.isVisible { second.close() }
        }
        XCTAssertTrue(first === same)
        XCTAssertFalse(first === second)
        let firstEditor = try await waitForNotesEditor(in: first)
        let secondEditor = try await waitForNotesEditor(in: second)
        firstEditor.insertText("First window 😀", replacementRange: NSRange(location: 0, length: 0))
        secondEditor.insertText("Second window", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(notes.buffer(sessionID: firstID), "First window 😀")
        XCTAssertEqual(notes.buffer(sessionID: secondID), "Second window")

        let closed = expectation(forNotification: NSWindow.willCloseNotification, object: first)
        first.performClose(nil)
        await fulfillment(of: [closed], timeout: 5)
        let persisted = await library.note(sessionID: firstID)
        XCTAssertEqual(persisted?.markdown, "First window 😀")
        XCTAssertTrue(second.isVisible)
        XCTAssertEqual(secondEditor.string, "Second window")
        let session = try await library.store.session(firstID)
        XCTAssertNil(session?.endedAt)
        let reopened = try XCTUnwrap(windows.open(sessionID: firstID, title: "Window One", date: nil, showInMain: {}))
        defer { reopened.close() }
        XCTAssertFalse(reopened === first)
        let reopenedEditor = try await waitForNotesEditor(in: reopened)
        XCTAssertEqual(reopenedEditor.string, "First window 😀")
    }

    private func waitForNotesEditor(in window: NSWindow) async throws -> MeetingNotesEditor.TextView {
        func editor(in view: NSView?) -> MeetingNotesEditor.TextView? {
            if let editor = view as? MeetingNotesEditor.TextView, editor.isEditable { return editor }
            return view?.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        for _ in 0..<80 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let view = editor(in: window.contentView) { return view }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(editor(in: window.contentView), "The detached notes editor “\(window.title)” did not become editable.")
    }

    func testUndoRedoFollowsTheDocumentAcrossLeasesAndReopening() async throws {
        let session = await makeSession()
        let first = UUID(), second = UUID(), reopened = UUID()
        await notes.load(sessionID: session)
        XCTAssertTrue(notes.claimEditor(first, sessionID: session))
        XCTAssertEqual(notes.replace(sessionID: session, editorID: first, generation: 0,
            range: NSRange(location: 0, length: 0), with: "😀"), 1)
        XCTAssertTrue(notes.claimEditor(second, sessionID: session))
        XCTAssertFalse(notes.canPerformHistory(.undo, sessionID: session, editorID: first))
        XCTAssertNil(notes.performHistory(.undo, sessionID: session, editorID: first))
        XCTAssertEqual(notes.replace(sessionID: session, editorID: second, generation: 1,
            range: NSRange(location: 2, length: 0), with: " café"), 2)
        let savedBeforeReopen = await notes.flush(sessionID: session)
        XCTAssertTrue(savedBeforeReopen)
        notes.unregisterEditor(second, sessionID: session)

        XCTAssertTrue(notes.claimEditor(reopened, sessionID: session))
        XCTAssertEqual(notes.performHistory(.undo, sessionID: session, editorID: reopened), NSRange(location: 2, length: 0))
        XCTAssertEqual(notes.buffer(sessionID: session), "😀")
        XCTAssertEqual(notes.performHistory(.undo, sessionID: session, editorID: reopened), NSRange(location: 0, length: 0))
        XCTAssertEqual(notes.buffer(sessionID: session), "")
        XCTAssertEqual(notes.performHistory(.redo, sessionID: session, editorID: reopened), NSRange(location: 2, length: 0))
        XCTAssertEqual(notes.buffer(sessionID: session), "😀")
        XCTAssertEqual(notes.performHistory(.redo, sessionID: session, editorID: reopened), NSRange(location: 7, length: 0))
        XCTAssertEqual(notes.buffer(sessionID: session), "😀 café")
        XCTAssertEqual(notes.performHistory(.undo, sessionID: session, editorID: reopened), NSRange(location: 2, length: 0))

        let nextGeneration = try XCTUnwrap(notes.draft(sessionID: session)?.generation)
        XCTAssertNotNil(notes.replace(sessionID: session, editorID: reopened, generation: nextGeneration,
            range: NSRange(location: 2, length: 0), with: " new"))
        XCTAssertFalse(notes.canPerformHistory(.redo, sessionID: session, editorID: reopened))
        let flushed = await notes.flush(sessionID: session)
        XCTAssertTrue(flushed)
        let saved = await library.note(sessionID: session)
        XCTAssertEqual(saved?.markdown, "😀 new")
    }

    func testNativeUndoRedoActionsPreserveHistoryAcrossModeAndEditorChanges() async throws {
        let session = await makeSession()
        await notes.load(sessionID: session)
        let first = UUID()
        let firstView = MeetingNotesEditor.TextView(frame: NSRect(x: 0, y: 0, width: 300, height: 220))
        let formatted = MeetingNotesEditor(notes: notes, sessionID: session, editorID: first,
            formatted: true, command: nil, commandID: UUID())
        let firstCoordinator = MeetingNotesEditor.Coordinator(formatted)
        firstView.delegate = firstCoordinator
        firstView.notesCoordinator = firstCoordinator
        firstCoordinator.attach(firstView)
        XCTAssertTrue(notes.claimEditor(first, sessionID: session))
        firstCoordinator.update(formatted)
        firstView.insertText("**😀**", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(firstView.string, "**😀**")

        let sourceMode = MeetingNotesEditor(notes: notes, sessionID: session, editorID: first,
            formatted: false, command: nil, commandID: UUID())
        firstCoordinator.update(sourceMode)
        XCTAssertTrue(NSApp.sendAction(#selector(MeetingNotesEditor.TextView.undoNote(_:)), to: firstView, from: nil))
        XCTAssertEqual(firstView.string, "")
        XCTAssertTrue(NSApp.sendAction(#selector(MeetingNotesEditor.TextView.redoNote(_:)), to: firstView, from: nil))
        XCTAssertEqual(firstView.string, "**😀**")
        firstCoordinator.detach()

        let second = UUID()
        let secondView = MeetingNotesEditor.TextView(frame: NSRect(x: 0, y: 0, width: 300, height: 220))
        let reopened = MeetingNotesEditor(notes: notes, sessionID: session, editorID: second,
            formatted: true, command: nil, commandID: UUID())
        let secondCoordinator = MeetingNotesEditor.Coordinator(reopened)
        secondView.delegate = secondCoordinator
        secondView.notesCoordinator = secondCoordinator
        secondCoordinator.attach(secondView)
        defer { secondCoordinator.detach() }
        XCTAssertTrue(notes.claimEditor(second, sessionID: session))
        secondCoordinator.update(reopened)
        XCTAssertEqual(secondView.string, "**😀**")
        XCTAssertTrue(NSApp.sendAction(#selector(MeetingNotesEditor.TextView.undoNote(_:)), to: secondView, from: nil))
        XCTAssertEqual(secondView.string, "")
        XCTAssertEqual(notes.buffer(sessionID: session), "")
        XCTAssertTrue(NSApp.sendAction(#selector(MeetingNotesEditor.TextView.redoNote(_:)), to: secondView, from: nil))
        XCTAssertEqual(notes.buffer(sessionID: session), "**😀**")
        XCTAssertEqual(secondView.selectedRange(), NSRange(location: 6, length: 0))
    }

    func testFailedFlushAllReportsAndRetainsDraft() async {
        let missing = UUID()
        notes.update(sessionID: missing, text: "Unsaved but recoverable")
        let failures = await notes.flushAll()
        XCTAssertEqual(failures, [missing])
        XCTAssertEqual(notes.buffer(sessionID: missing), "Unsaved but recoverable")
        XCTAssertTrue(notes.draft(sessionID: missing)?.isDirty == true)
    }

    func testEditorStateIsKeptPerSession() {
        let a = UUID(), b = UUID()
        notes.setEditorState(sessionID: a, selection: NSRange(location: 3, length: 2), scrollPoint: NSPoint(x: 1, y: 2))
        XCTAssertEqual(notes.editorState(sessionID: a).selection, NSRange(location: 3, length: 2))
        XCTAssertNil(notes.editorState(sessionID: b).selection)
        notes.discard(sessionID: a)
        XCTAssertNil(notes.editorState(sessionID: a).selection)
        XCTAssertNil(notes.draft(sessionID: a))
    }

    func testFlushAllCommitsEveryDirtyDraft() async {
        let a = await makeSession(UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, title: "One")
        let b = await makeSession(UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!, title: "Two")
        notes.update(sessionID: a, text: "one")
        notes.update(sessionID: b, text: "two")
        await notes.flushAll()
        let noteA = await library.note(sessionID: a)
        let noteB = await library.note(sessionID: b)
        XCTAssertEqual(noteA?.markdown, "one")
        XCTAssertEqual(noteB?.markdown, "two")
    }
}

@MainActor final class MeetingMarkdownPreviewTests: XCTestCase {
    func testUTF16RangesAndCodeIsolation() throws {
        let source = """
        # 😀 **жирный** *é* ~~strike~~ [link](https://example.invalid)

        ```markdown
        # **raw** - [x]
        ```

        - [x] done
        """
        let lines = MeetingMarkdownPreview.lines(in: source)
        let heading = try XCTUnwrap(lines.first { $0.heading == 1 })
        let bold = try XCTUnwrap(heading.spans.first { $0.style == .bold })
        XCTAssertEqual((source as NSString).substring(with: bold.range), "жирный")
        let italic = try XCTUnwrap(heading.spans.first { $0.style == .italic })
        XCTAssertEqual((source as NSString).substring(with: italic.range), "é")
        XCTAssertTrue(heading.spans.contains { $0.style == .link })
        XCTAssertTrue(heading.spans.contains { $0.style == .strike })
        let code = lines.filter(\.code)
        XCTAssertEqual(code.count, 3)
        XCTAssertTrue(code.allSatisfy { $0.spans.isEmpty && $0.checklist == nil })
        let checkbox = try XCTUnwrap(lines.last?.checklist)
        XCTAssertEqual((source as NSString).substring(with: checkbox), "x")
    }

    func testTableRuleAndIncompleteSyntax() throws {
        let source = """
        | Header | Column |
        | --- | --- |
        | One | Two |

        ---

        *incomplete [link](

        **hello
        world**
        """
        let lines = MeetingMarkdownPreview.lines(in: source)
        XCTAssertEqual(lines.filter(\.table).count, 2)
        XCTAssertEqual(lines.filter(\.tableDelimiter).count, 1)
        XCTAssertEqual(lines.filter(\.table).map { $0.tableRow?.dividerIndices.count ?? 0 }, [3, 3])
        XCTAssertEqual(lines.filter(\.rule).count, 1)
        XCTAssertEqual(lines.filter { $0.spans.contains { $0.style == .bold } }.count, 2)
        XCTAssertFalse(lines.contains { (source as NSString).substring(with: $0.range).contains("incomplete") })
    }

    func testUTF8SourceColumnsMapToFoundationUTF16Ranges() throws {
        for source in [
            "# 😀 **жирный** *é* [🕴️](https://example.invalid)",
            "**hello\r\nworld**\r\n\r\n- [x] A\r\n  1. nested",
            "> **العربية**\r> _日本語_\r\r```\r# **raw**\r```",
            "| α | β |\n| --- | --- |\n| 🇫🇮 | 🥹 |",
            "\t```\n\tcode\n\t```"
        ] {
            let parsed = try AttributedString(markdown: source, options: .init(appliesSourcePositionAttributes: true))
            let offsets = MeetingMarkdownPreview.SourceOffsets(source)
            for run in parsed.runs {
                guard let position = run.markdownSourcePosition else { continue }
                if let mapped = offsets.range(position) {
                    XCTAssertEqual(mapped, Range(position, in: source).map { NSRange($0, in: source) }, "\(position) in \(source)")
                }
            }
        }
    }

    func testRangeReplacementPreservesComposedSequencesAndCanonicalSource() {
        for (old, new) in [
            ("a 😀 end", "a 😁 end"),
            ("a 🇫🇮 end", "a 🇫🇷 end"),
            ("a é end", "a é end"),
            ("abcdef", "ab"),
            ("end", "a end"),
            ("a end", "end"),
            ("", "🕴️"),
            ("remove", "")
        ] {
            let change = MeetingNotesEditor.Coordinator.edit(from: old, to: new)
            let rebuilt = (old as NSString).replacingCharacters(in: change.range, with: change.replacement)
            XCTAssertEqual(Array(rebuilt.utf16), Array(new.utf16))
        }
    }
}
