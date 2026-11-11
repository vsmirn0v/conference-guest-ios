import Foundation
import XCTest
@testable import RockNativeDesktop

final class ObsidianSharedExportTests: XCTestCase {
    private func fixture(mode: ObsidianExportMode, layout: ObsidianExportLayout,
                         perform: (MeetingLibraryStore, ObsidianDestinationRecord, URL, ObsidianExportWorker, ObsidianFileWriter) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        let backups = root.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingLibraryStore(root: root)
        try await store.prepare()
        let destination = ObsidianDestinationRecord(enabled: true, saveAfterMeeting: false, syncChanges: true,
            mode: mode, layout: layout, configRevision: 1, vaultBookmark: Data([1]))
        try await store.saveDestination(destination)
        let writer = ObsidianFileWriter(backupRoot: backups)
        let worker = ObsidianExportWorker(store: store, backupRoot: backups, writer: writer,
            vaultResolver: { _ in .granted(vault) })
        do {
            try await perform(store, destination, vault, worker, writer)
            await store.close()
        } catch {
            await store.close()
            throw error
        }
    }

    func testSharedWorklogPreservesManualRegionsAndUpdatesSameBlock() async throws {
        var layout = ObsidianExportLayout(documentPath: "Runtime.md", timeZoneID: "UTC",
            startAfter: "INTRO END", endBefore: "## Conclusion")
        layout.applyRuntimePreset()
        let original = "---\nmanual: yes\n---\n# My log\nINTRO END\n### 5.01\nManual entry\n## Conclusion\nKeep me\n"
        let legacy = try ObsidianWorklogPlacement.legacyRuntimeDays(in: MarkdownStructureScanner.scan(original), layout: layout)
        layout.legacyRuntimeYears = ["Runtime.md": [try XCTUnwrap(legacy.first?.id): 2025]]
        try await fixture(mode: .worklog, layout: layout) { store, destination, vault, worker, _ in
            let target = vault.appendingPathComponent("Runtime.md")
            try original.write(to: target, atomically: true, encoding: .utf8)
            let iso = ISO8601DateFormatter()
            let date = try XCTUnwrap(iso.date(from: "2026-01-05T12:00:00Z"))
            let first = MeetingSessionRecord(title: "First sync", startedAt: date)
            let second = MeetingSessionRecord(title: "Second sync", startedAt: date.addingTimeInterval(60))
            for item in [first, second] {
                try await store.upsertSession(item)
                _ = try await store.saveNote(sessionID: item.id, markdown: "Saved note for " + item.title)
                try await store.saveInObsidian(item.id)
                await worker.runOnce()
            }
            let output = try String(contentsOf: target, encoding: .utf8)
            XCTAssertTrue(output.hasPrefix("---\nmanual: yes\n---\n# My log\nINTRO END\n"))
            XCTAssertTrue(output.hasSuffix("## Conclusion\nKeep me\n"))
            XCTAssertTrue(output.contains("### 5.01\nManual entry"))
            XCTAssertTrue(output.contains("<!-- rnr:day 2026-01-05 -->"))
            XCTAssertEqual(output.components(separatedBy: "### 5.01").count, 3)
            let firstRange = try XCTUnwrap(output.range(of: "**First sync**"))
            let secondRange = try XCTUnwrap(output.range(of: "**Second sync**"))
            XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
            let before = try await store.binding(destinationID: destination.id, sessionID: first.id, component: .worklog)
            _ = try await store.saveNote(sessionID: first.id, markdown: "Late revision")
            await worker.runOnce()
            let after = try await store.binding(destinationID: destination.id, sessionID: first.id, component: .worklog)
            XCTAssertEqual(before?.markerID, after?.markerID)
            XCTAssertEqual(before?.relativePath, after?.relativePath)
            XCTAssertGreaterThan(after?.lastExportedRevision ?? 0, before?.lastExportedRevision ?? 0)
            let updated = try String(contentsOf: target, encoding: .utf8)
            XCTAssertTrue(updated.contains("Late revision"))
            XCTAssertEqual(updated.components(separatedBy: "**First sync**").count, 2)
        }
    }

    func testHybridRetainsPartialUntilBothComponentsConverge() async throws {
        let layout = ObsidianExportLayout(documentPath: "Index/Meetings.md", timeZoneID: "UTC")
        try await fixture(mode: .filesAndIndex, layout: layout) { store, destination, vault, worker, writer in
            let index = vault.appendingPathComponent(layout.documentPath)
            try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "Index preamble\n".write(to: index, atomically: true, encoding: .utf8)
            let session = MeetingSessionRecord(title: "Hybrid", startedAt: Date())
            try await store.upsertSession(session)
            let note = try await store.saveNote(sessionID: session.id, markdown: "Frozen notes")
            try await store.saveInObsidian(session.id)
            await writer.injectFaults([.beforeBackup])
            await worker.runOnce()

            let partial = try await store.partialObsidianDeliveryCount(destinationID: destination.id)
            let complete = try await store.latestObsidianDelivery(destinationID: destination.id)
            XCTAssertEqual(partial, 1)
            XCTAssertNil(complete)
            let meeting = try await store.binding(destinationID: destination.id, sessionID: session.id, component: .meeting)
            XCTAssertEqual(meeting?.lastExportedRevision, note.exportRevision)
            _ = try await store.saveNote(sessionID: session.id, markdown: "While only partially linked")
            let pending = try await store.outboxRows(destinationID: destination.id)
            XCTAssertEqual(pending.first?.desiredRevision, note.exportRevision)

            await writer.injectFaults([])
            await worker.runOnce(now: Date().addingTimeInterval(10))
            let partialAfter = try await store.partialObsidianDeliveryCount(destinationID: destination.id)
            let completeAfter = try await store.latestObsidianDelivery(destinationID: destination.id)
            let count = try await store.outboxCount()
            XCTAssertEqual(partialAfter, 0)
            XCTAssertEqual(completeAfter?.revision, note.exportRevision)
            XCTAssertEqual(count, 0)
            let output = try String(contentsOf: index, encoding: .utf8)
            XCTAssertTrue(output.hasPrefix("Index preamble\n"))
            XCTAssertTrue(output.contains("../Meetings/Hybrid%20"))
            XCTAssertTrue(output.contains("Open tasks: 0"))

            let next = try await store.saveNote(sessionID: session.id, markdown: "After complete link")
            let linked = try await store.outboxRows(destinationID: destination.id)
            XCTAssertEqual(linked.first?.desiredRevision, next.exportRevision)
            XCTAssertEqual(linked.first?.intent, .linkedUpdate)
        }
    }

    func testRenameUpdatesOwnedMetadataAndPreservesForeignYAMLAndPath() async throws {
        try await fixture(mode: .separateFiles, layout: .init()) { store, destination, vault, worker, _ in
            let session = MeetingSessionRecord(title: "Initial title", startedAt: Date())
            try await store.upsertSession(session)
            _ = try await store.saveNote(sessionID: session.id, markdown: "Saved note")
            try await store.saveInObsidian(session.id)
            await worker.runOnce()
            let first = try await store.binding(destinationID: destination.id, sessionID: session.id, component: .meeting)
            let binding = try XCTUnwrap(first)
            XCTAssertNotNil(binding.lastMetadataSHA256)
            let target = vault.appendingPathComponent(binding.relativePath)
            let text = try String(contentsOf: target, encoding: .utf8)
            let manual = String(text.prefix(4)) + "custom: \"Keep\"\n" + text.dropFirst(4) + "\nForeign conclusion\n"
            try manual.write(to: target, atomically: true, encoding: .utf8)

            try await store.renameSession(session.id, title: "Renamed meeting")
            await worker.runOnce()
            let updated = try String(contentsOf: target, encoding: .utf8)
            XCTAssertTrue(updated.contains("title: \"Renamed meeting\""))
            XCTAssertTrue(updated.contains("# Renamed meeting"))
            XCTAssertTrue(updated.contains("custom: \"Keep\""))
            XCTAssertTrue(updated.hasSuffix("\nForeign conclusion\n"))
            let renamed = try await store.binding(destinationID: destination.id, sessionID: session.id, component: .meeting)
            XCTAssertEqual(renamed?.relativePath, binding.relativePath)
            XCTAssertNotEqual(renamed?.lastMetadataSHA256, binding.lastMetadataSHA256)

            let edited = updated.replacingOccurrences(of: "title: \"Renamed meeting\"", with: "title: \"External edit\"")
            try edited.write(to: target, atomically: true, encoding: .utf8)
            try await store.renameSession(session.id, title: "Do not overwrite")
            await worker.runOnce()
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), edited)
            let conflict = try await store.outboxRows(destinationID: destination.id)
            XCTAssertTrue(conflict.first?.paused == true)
        }
    }

    func testRuntimeRefusesLegacyDatesUntilYearIsConfirmed() throws {
        let session = MeetingSessionRecord(title: "Test", startedAt: Date())
        let snapshot = ObsidianExportSnapshot(session: session, note: nil, outcome: nil, outcomeState: .notStarted)
        var layout = ObsidianExportLayout(documentPath: "Runtime.md")
        layout.applyRuntimePreset()
        let destination = ObsidianDestinationRecord(mode: .worklog, layout: layout)
        let binding = ObsidianExportBindingRecord(destinationID: destination.id, sessionID: session.id, component: .worklog,
            relativePath: layout.documentPath, markerID: ManagedBlock.newNonce(), lastExportedRevision: 0,
            lastBlockSHA256: nil, lastFileSHA256: nil, state: .idle, errorCode: nil, updatedAt: Date())
        XCTAssertThrowsError(try ObsidianComponentRenderer.patch(existing: "### 5.01\nManual\n",
            binding: binding, destination: destination, snapshot: snapshot, meetingRelativePath: nil)) { error in
                guard case ObsidianExportError.placementConflict = error else { return XCTFail("Unexpected error: \(error)") }
            }
    }

    func testWorklogInsertionOrderingAcrossPlacementOptions() throws {
        let source = "Introduction\nSTART\n### 2026-11-09\nEarlier manual entry\n### 2026-11-11\nLater manual entry\nEND\nConclusion\n"
        let lines = MarkdownStructureScanner.scan(source)
        func insertion(_ layout: ObsidianExportLayout, _ day: String) throws -> (String, String?) {
            let insertion = try ObsidianWorklogPlacement.insertion(in: source, structure: lines,
                component: .worklog, dateKey: day, layout: layout)
            let bytes = Data(source.utf8)
            return (String(decoding: bytes.prefix(insertion.offset), as: UTF8.self), insertion.heading)
        }
        var layout = ObsidianExportLayout(startAfter: "START", endBefore: "END")
        layout.insertAtBeginning = true
        XCTAssertEqual(try insertion(layout, "2026-11-10").0, "Introduction\nSTART\n")
        layout.insertAtBeginning = false
        XCTAssertTrue(try insertion(layout, "2026-11-10").0.hasSuffix("Later manual entry\n"))
        layout.groupByDay = true
        layout.newestDaysFirst = false
        let middle = try insertion(layout, "2026-11-10")
        XCTAssertTrue(middle.0.hasSuffix("Earlier manual entry\n"))
        XCTAssertTrue(middle.1?.contains("2026-11-10") == true)
        layout.withinDayAtBeginning = true
        XCTAssertTrue(try insertion(layout, "2026-11-09").0.hasSuffix("### 2026-11-09\n"))
        layout.withinDayAtBeginning = false
        XCTAssertTrue(try insertion(layout, "2026-11-09").0.hasSuffix("Earlier manual entry\n"))
        let reversed = "Introduction\nSTART\n### 2026-11-11\nLater manual entry\n### 2026-11-09\nEarlier manual entry\nEND\nConclusion\n"
        layout.newestDaysFirst = true
        let newest = try ObsidianWorklogPlacement.insertion(in: reversed, structure: MarkdownStructureScanner.scan(reversed),
            component: .worklog, dateKey: "2026-11-10", layout: layout)
        XCTAssertTrue(String(decoding: Data(reversed.utf8).prefix(newest.offset), as: UTF8.self).hasSuffix("Later manual entry\n"))
    }

    func testBeginningOfExistingUnmanagedWorklogRequiresExplicitBoundary() throws {
        let source = "---\ntitle: Journal\n---\nIntroduction\nManual entry\nConclusion\n"
        var layout = ObsidianExportLayout()
        layout.insertAtBeginning = true
        XCTAssertThrowsError(try ObsidianWorklogPlacement.insertion(in: source,
            structure: MarkdownStructureScanner.scan(source), component: .worklog,
            dateKey: "2026-11-12", layout: layout)) { error in
                guard case ObsidianExportError.placementConflict = error else { return XCTFail("Unexpected error: \(error)") }
            }
        layout.startAfter = "Introduction"
        layout.endBefore = "Conclusion"
        let insertion = try ObsidianWorklogPlacement.insertion(in: source,
            structure: MarkdownStructureScanner.scan(source), component: .worklog,
            dateKey: "2026-11-12", layout: layout)
        XCTAssertEqual(String(decoding: Data(source.utf8).prefix(insertion.offset), as: UTF8.self),
            "---\ntitle: Journal\n---\nIntroduction\n")
    }

    func testRuntimePlacesIdenticalDayHeadingsInExplicitlyConfirmedYears() throws {
        let original = """
        # Runtime

        ### 5.01
        Manual entry for the more recent section

        ### 5.01
        Manual entry for the older section

        ## Conclusion
        Preserve this
        """
        var layout = ObsidianExportLayout(documentPath: "Runtime.md", timeZoneID: "UTC", endBefore: "## Conclusion")
        layout.applyRuntimePreset()
        let headings = try ObsidianWorklogPlacement.legacyRuntimeDays(in: MarkdownStructureScanner.scan(original), layout: layout)
        XCTAssertEqual(headings.map(\.title), ["5.01", "5.01"])
        XCTAssertEqual(headings.map(\.lineNumber), [3, 6])
        XCTAssertEqual(headings.map(\.context), ["Manual entry for the more recent section", "Manual entry for the older section"])
        guard headings.count == 2 else { return }
        XCTAssertNotEqual(headings[0].id, headings[1].id)
        layout.legacyRuntimeYears = ["Runtime.md": [headings[0].id: 2025, headings[1].id: 2024]]
        let destination = ObsidianDestinationRecord(mode: .worklog, layout: layout)
        let iso = ISO8601DateFormatter()

        func export(_ source: String, year: Int, title: String) throws -> String {
            let date = try XCTUnwrap(iso.date(from: "\(year)-01-05T12:00:00Z"))
            let session = MeetingSessionRecord(title: title, startedAt: date)
            let snapshot = ObsidianExportSnapshot(session: session, note: nil, outcome: nil, outcomeState: .notStarted)
            let binding = ObsidianExportBindingRecord(destinationID: destination.id, sessionID: session.id, component: .worklog,
                relativePath: "Runtime.md", markerID: ManagedBlock.newNonce(), lastExportedRevision: 0,
                lastBlockSHA256: nil, lastFileSHA256: nil, state: .idle, errorCode: nil, updatedAt: Date())
            return try ObsidianComponentRenderer.patch(existing: source, binding: binding, destination: destination,
                snapshot: snapshot, meetingRelativePath: nil).text
        }

        let withNewer = try export(original, year: 2025, title: "Newer meeting")
        let withBoth = try export(withNewer, year: 2024, title: "Older meeting")
        let positions = try [
            "Manual entry for the more recent section", "**Newer meeting**",
            "Manual entry for the older section", "**Older meeting**", "## Conclusion",
        ].map { try XCTUnwrap(withBoth.range(of: $0)?.lowerBound) }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(withBoth.components(separatedBy: "### 5.01").count, 3)
        XCTAssertFalse(withBoth.contains("<!-- rnr:day "))
        XCTAssertEqual(try ObsidianWorklogPlacement.legacyRuntimeDays(
            in: MarkdownStructureScanner.scan(withBoth), layout: layout).map(\.id), headings.map(\.id))
    }

    func testRuntimeYearConfirmationRejectsEditedSectionsAndDuplicateFullDates() throws {
        let original = "### 5.01\nFirst section\n\n### 5.01\nSecond section\n"
        let structure = MarkdownStructureScanner.scan(original)
        var layout = ObsidianExportLayout(documentPath: "Runtime.md")
        layout.applyRuntimePreset()
        let headings = try ObsidianWorklogPlacement.legacyRuntimeDays(in: structure, layout: layout)
        guard headings.count == 2 else { return XCTFail("Expected both legacy day headings.") }
        layout.legacyRuntimeYears = ["Runtime.md": [headings[0].id: 2025, headings[1].id: 2025]]
        XCTAssertThrowsError(try ObsidianWorklogPlacement.insertion(in: original, structure: structure,
            component: .worklog, dateKey: "2025-01-05", layout: layout))
        layout.legacyRuntimeYears?["Runtime.md"]?[headings[1].id] = 2024
        let changed = original.replacingOccurrences(of: "Second section", with: "Edited second section")
        XCTAssertThrowsError(try ObsidianWorklogPlacement.insertion(in: changed,
            structure: MarkdownStructureScanner.scan(changed), component: .worklog, dateKey: "2024-01-05", layout: layout))
        XCTAssertThrowsError(try ObsidianWorklogPlacement.insertion(in: original, structure: structure,
            component: .worklog, dateKey: "2025-01-05", layout: layout, relativePath: "Different Runtime.md"))
        XCTAssertNotNil(try ObsidianWorklogPlacement.insertion(in: original, structure: structure,
            component: .worklog, dateKey: "2024-01-05", layout: layout, relativePath: "Runtime.md"))
    }

    func testRuntimeYearConfirmationInvalidatesChangedIdenticalSectionSet() throws {
        let original = "### 5.01\nIdentical entry\n\n### 5.01\nIdentical entry\n"
        var layout = ObsidianExportLayout(documentPath: "Runtime.md")
        layout.applyRuntimePreset()
        let structure = MarkdownStructureScanner.scan(original)
        let headings = try ObsidianWorklogPlacement.legacyRuntimeDays(in: structure, layout: layout)
        guard headings.count == 2 else { return XCTFail("Expected two identical legacy day headings.") }
        XCTAssertNotEqual(headings[0].id, headings[1].id)
        layout.legacyRuntimeYears = ["Runtime.md": [headings[0].id: 2025, headings[1].id: 2024]]
        _ = try ObsidianWorklogPlacement.insertion(in: original, structure: structure,
            component: .worklog, dateKey: "2025-01-05", layout: layout)
        let changed = "### 5.01\nIdentical entry\n\n" + original
        XCTAssertThrowsError(try ObsidianWorklogPlacement.insertion(in: changed,
            structure: MarkdownStructureScanner.scan(changed), component: .worklog, dateKey: "2025-01-05", layout: layout))
    }

    func testConfirmedRuntimeYearsResumePlacementConflicts() async throws {
        var runtime = ObsidianExportLayout(documentPath: "Runtime.md", timeZoneID: "UTC")
        runtime.applyRuntimePreset()
        try await fixture(mode: .worklog, layout: runtime) { store, initial, vault, worker, _ in
            let target = vault.appendingPathComponent("Runtime.md")
            let text = "### 5.01\nNewer manual section\n\n### 5.01\nOlder manual section\n"
            try text.write(to: target, atomically: true, encoding: .utf8)
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2024-01-05T12:00:00Z"))
            let meeting = MeetingSessionRecord(title: "Resume placement", startedAt: date)
            try await store.upsertSession(meeting)
            _ = try await store.saveNote(sessionID: meeting.id, markdown: "Queued note")
            try await store.saveInObsidian(meeting.id)
            await worker.runOnce()
            let blocked = try await store.outboxRows(destinationID: initial.id)
            XCTAssertEqual(blocked.first?.paused, true)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), text)

            var confirmed = initial
            let headings = try ObsidianWorklogPlacement.legacyRuntimeDays(
                in: MarkdownStructureScanner.scan(text), layout: runtime)
            guard headings.count == 2 else { return XCTFail("Expected two legacy day headings.") }
            confirmed.layout.legacyRuntimeYears = ["Runtime.md": [headings[0].id: 2025, headings[1].id: 2024]]
            confirmed.configRevision += 1
            try await store.saveDestination(confirmed)
            await worker.runOnce()
            let remaining = try await store.outboxRows(destinationID: initial.id)
            XCTAssertTrue(remaining.isEmpty)
            let patched = try String(contentsOf: target, encoding: .utf8)
            XCTAssertTrue(patched.contains("Older manual section\n\n"))
            XCTAssertTrue(patched.hasSuffix(" -->\n"))
            XCTAssertTrue(patched.contains("**Resume placement**"))
        }
    }

    func testFiveMiBWorklogCommitToExportLatency() async throws {
        let layout = ObsidianExportLayout(documentPath: "Benchmark.md", timeZoneID: "UTC")
        try await fixture(mode: .worklog, layout: layout) { store, destination, vault, worker, _ in
            let target = vault.appendingPathComponent(layout.documentPath)
            let worklogBytes = 5 * 1024 * 1024
            let noteBytes = 100 * 1024
            let line = "- A saved Markdown note with a representative task, decision, and follow-up.\n"
            let noteBody = String(repeating: line, count: (noteBytes - 64) / line.utf8.count)
            func note(_ sample: Int) -> String {
                let label = String(format: "Revision %02d\n\n", sample) + noteBody
                return label + String(repeating: "x", count: noteBytes - label.utf8.count)
            }
            let preamble = "# Synthetic worklog\n\n"
            var seed = preamble
            for index in 0..<50 {
                let suffix = String(format: "%012d", index)
                let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-" + suffix))
                let nonce = ManagedBlock.newNonce()
                seed += ManagedBlock.beginMarker(sessionID: id, nonce: nonce, component: .worklog) + "\n"
                seed += "### Historical meeting \(index)\n\n"
                seed += String(repeating: line, count: (100 * 1024 - 1200) / line.utf8.count)
                seed += ManagedBlock.endMarker(sessionID: id, nonce: nonce, component: .worklog) + "\n\n"
            }
            XCTAssertLessThan(seed.utf8.count + noteBytes + 1024, worklogBytes)
            try seed.write(to: target, atomically: true, encoding: .utf8)
            let session = MeetingSessionRecord(title: "Benchmark meeting", startedAt: Date())
            try await store.upsertSession(session)
            let initial = try await store.saveNote(sessionID: session.id, markdown: note(0))
            try await store.saveInObsidian(session.id)
            await worker.runOnce()
            let linked = try await store.latestObsidianDelivery(destinationID: destination.id)
            XCTAssertEqual(linked?.revision, initial.exportRevision)
            var existing = try Data(contentsOf: target)
            guard existing.count <= worklogBytes else { return XCTFail("Worklog fixture exceeds 5 MiB.") }
            if existing.count < worklogBytes {
                let count = worklogBytes - existing.count
                var padding = Data(repeating: 120, count: count - 1)
                padding.append(10)
                existing.insert(contentsOf: padding, at: preamble.utf8.count)
                try existing.write(to: target, options: .atomic)
            }

            await worker.start()
            defer { worker.stop() }
            var milliseconds: [Double] = []
            let clock = ContinuousClock()
            for sample in 1...12 {
                let commit = try await store.saveNote(sessionID: session.id, markdown: note(sample))
                let committedAt = clock.now
                let deadline = committedAt.advanced(by: .seconds(5))
                while clock.now < deadline {
                    let receipt = try await store.latestObsidianDelivery(destinationID: destination.id)
                    if receipt?.revision == commit.exportRevision {
                        let elapsed = committedAt.duration(to: clock.now).components
                        milliseconds.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard milliseconds.count == sample else { return XCTFail("No export receipt for sample \(sample).") }
            }
            let sorted = milliseconds.sorted()
            let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
            let maximum = sorted[sorted.count - 1]
            let exported = try Data(contentsOf: target)
            XCTAssertEqual(exported.count, worklogBytes)
            XCTAssertTrue(String(decoding: exported, as: UTF8.self).contains("Revision 12\n\n"))
            let formatted = milliseconds.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            print("Obsidian 5 MiB commit-to-complete receipt (ms): [\(formatted)] p95=\(String(format: "%.1f", p95)) max=\(String(format: "%.1f", maximum))")
            XCTAssertLessThanOrEqual(maximum, 2_000)
        }
    }
}
