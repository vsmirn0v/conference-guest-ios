import AppKit
import CoreImage
import LiveKitWebRTC
import SwiftUI
import Vision
import VisionKit
import XCTest
@testable import RockNativeDesktop

@MainActor final class DesktopSharedTextTests: XCTestCase {
    func testRecognitionAndCaptureRemainOwnedAfterSourceEnds() async throws {
        let image = try textImage()
        let frame = NativeDesktopTextFrame(); frame.provider = .init(sourceID: "one", capture: { image })
        let selection = NativeDesktopSharedText()
        selection.updateSource(id: "one", name: "Alex", frame: frame); selection.open()
        try await wait { !selection.busy }
        let snapshot = try XCTUnwrap(selection.snapshot)
        XCTAssertEqual(snapshot.image.width, 1600); XCTAssertEqual(snapshot.image.height, 900)
        if ImageAnalyzer.isSupported { XCTAssertTrue(selection.analysis?.hasResults(for: .text) == true) }
        else { XCTAssertFalse(selection.transcript.isEmpty) }
        let host = NSHostingView(rootView: NativeDesktopSharedTextView(model: selection))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 650)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Synthetic shared-text validation"; window.contentView = host; window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let rendered = NSImage(size: host.bounds.size); rendered.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: rendered); attachment.name = "Native captured share with real Live Text overlay"; attachment.lifetime = .keepAlways; add(attachment)
        }
        window.close()
        selection.updateSource(id: nil, name: "", frame: frame)
        XCTAssertEqual(selection.liveState, .ended); XCTAssertFalse(selection.canRefresh)
        XCTAssertEqual(selection.snapshot?.id, snapshot.id)
        selection.updateSource(id: "two", name: "Sam", frame: frame)
        XCTAssertEqual(selection.liveState, .changed); XCTAssertTrue(selection.canRefresh)
        frame.provider = .init(sourceID: "two", capture: { image })
        selection.refresh(); try await wait { !selection.busy }
        XCTAssertEqual(selection.snapshot?.sourceID, "two"); XCTAssertEqual(selection.snapshot?.sourceName, "Sam")
        XCTAssertNotEqual(selection.snapshot?.id, snapshot.id)
        selection.close(); XCTAssertNil(selection.snapshot); XCTAssertNil(selection.analysis); XCTAssertFalse(selection.isOpen)
    }
    func testCloseRejectsLateCaptureFromPreviousMeeting() async throws {
        let image = try textImage(), frame = NativeDesktopTextFrame()
        var continuation: CheckedContinuation<CGImage?, Never>?
        frame.provider = .init(sourceID: "one", capture: { await withCheckedContinuation { continuation = $0 } })
        let selection = NativeDesktopSharedText()
        selection.updateSource(id: "one", name: "Alex", frame: frame); selection.open()
        for _ in 0..<20 where continuation == nil { await Task.yield() }
        XCTAssertNotNil(continuation); selection.close()
        continuation?.resume(returning: image)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(selection.isOpen); XCTAssertNil(selection.snapshot); XCTAssertNil(selection.analysis)
    }
    func testMixedCyrillicAndLatinRecognitionOnSupportedSystem() async throws {
        let supported: [String]
        if ImageAnalyzer.isSupported { supported = ImageAnalyzer.supportedTextRecognitionLanguages }
        else {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            supported = try request.supportedRecognitionLanguages()
        }
        let evidence = "OCR supported languages: \(supported.joined(separator: ", "))\nPreferred languages: \(Locale.preferredLanguages.joined(separator: ", "))"
        let attachment = XCTAttachment(string: evidence)
        attachment.name = "Mixed-language OCR system capabilities"; attachment.lifetime = .keepAlways; add(attachment)
        guard supported.contains(where: { Locale(identifier: $0).languageCode == "ru" }) else {
            throw XCTSkip("This OS OCR engine does not advertise Russian recognition. " + evidence)
        }
        let image = try textImage("Release review\nПроверка текста")
        let frame = NativeDesktopTextFrame(); frame.provider = .init(sourceID: "mixed", capture: { image })
        let selection = NativeDesktopSharedText(); defer { selection.close() }
        selection.updateSource(id: "mixed", name: "Synthetic bilingual share", frame: frame); selection.open()
        try await wait { !selection.busy }
        let transcript = selection.analysis?.transcript ?? selection.transcript
        XCTAssertTrue(transcript.contains("Release"), "Latin text missing: \(transcript)")
        XCTAssertTrue(transcript.contains("Проверка"), "Cyrillic text missing: \(transcript)")
    }
    func testUnsupportedRotationRejectedAndRightRotationKeepsResolution() throws {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        let image = try XCTUnwrap(SharedTextImage.oriented(buffer, rotation: 270))
        let captured = try XCTUnwrap(SharedTextImage.materialize(image))
        XCTAssertEqual(captured.width, 180); XCTAssertEqual(captured.height, 320)
        XCTAssertNil(SharedTextImage.oriented(buffer, rotation: 1))
    }
    func testFrozenImageSupportsBoundedNativeZoomWithoutChangingPixelGeometry() throws {
        let scroll = NativeDesktopTextScroll(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let image = try textImage()
        scroll.imageDocument.image.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        scroll.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroll.allowsMagnification)
        XCTAssertEqual(scroll.minMagnification, 1); XCTAssertEqual(scroll.maxMagnification, 8)
        scroll.magnification = 2
        XCTAssertEqual(scroll.magnification, 2)
        XCTAssertTrue(scroll.imageDocument.overlay.trackingImageView === scroll.imageDocument.image)
        XCTAssertEqual(image.width, 1600); XCTAssertEqual(image.height, 900)
    }
    func testClosedCapturePreventsOverlappingReopenUntilFinished() async throws {
        let image = try textImage(), frame = NativeDesktopTextFrame()
        var pending: [CheckedContinuation<CGImage?, Never>] = []
        frame.provider = .init(sourceID: "one", capture: { await withCheckedContinuation { pending.append($0) } })
        let selection = NativeDesktopSharedText()
        selection.updateSource(id: "one", name: "Alex", frame: frame); selection.open()
        for _ in 0..<30 where pending.count < 1 { await Task.yield() }
        XCTAssertEqual(pending.count, 1); selection.close(); selection.open()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(pending.count, 1, "Reopening must not overlap an old system capture/recognition job")
        XCTAssertFalse(selection.busy)
        pending[0].resume(returning: nil)
        for _ in 0..<20 { await Task.yield() }
        selection.refresh()
        for _ in 0..<30 where pending.count < 2 { await Task.yield() }
        XCTAssertEqual(pending.count, 2)
        guard pending.count == 2 else { selection.close(); return }
        XCTAssertTrue(selection.busy)
        selection.close(); pending[1].resume(returning: image)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(selection.isOpen); XCTAssertFalse(selection.busy); XCTAssertNil(selection.snapshot)
    }
    func testSourceReplacementCannotRelabelNewPixelsWithPreviousSourceName() async throws {
        let frame = NativeDesktopTextFrame()
        var firstCalls = 0, replacementCalls = 0
        frame.provider = .init(sourceID: "A", capture: { firstCalls += 1; return nil })
        let selection = NativeDesktopSharedText()
        selection.updateSource(id: "A", name: "Alex", frame: frame); selection.open()
        frame.provider = .init(sourceID: "B", capture: { replacementCalls += 1; return nil })
        selection.updateSource(id: "B", name: "Sam", frame: frame)
        try await wait { !selection.busy }
        XCTAssertEqual(firstCalls, 1); XCTAssertEqual(replacementCalls, 0)
        XCTAssertNil(selection.snapshot)
        selection.close()
    }
    func testMosaicCropChangeRejectsPreviousCaptureProvider() async throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let sink = CompanionVideoSink(mirrored: false); defer { sink.stop() }
        let left = CGRect(x: 0, y: 0, width: 0.5, height: 1), right = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        sink.setPresentation(crop: left, zoom: 1, pan: .zero)
        sink.renderFrame(LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels)), rotation: ._0, timeStampNs: 1))
        try await wait { sink.preparationEvidenceForTesting["preparedTimestamp"] == 1 }
        let first = await sink.snapshotImage(expectedCrop: left)
        XCTAssertEqual(first?.width, 320); XCTAssertEqual(first?.height, 360)
        sink.setPresentation(crop: right, zoom: 1, pan: .zero)
        let stale = await sink.snapshotImage(expectedCrop: left)
        XCTAssertNil(stale, "A shared RTC track must not return the replacement participant's crop through an old provider")
        let replacement = await sink.snapshotImage(expectedCrop: right)
        XCTAssertEqual(replacement?.width, 320)
    }
    func testMismatchedSemanticProviderIsNotCaptured() async throws {
        let frame = NativeDesktopTextFrame(); var captured = false
        frame.provider = .init(sourceID: "B", capture: { captured = true; return nil })
        let selection = NativeDesktopSharedText()
        selection.updateSource(id: "A", name: "Alex", frame: frame); selection.open()
        try await wait { !selection.busy }
        XCTAssertFalse(captured); XCTAssertNil(selection.snapshot); selection.close()
    }
    func testDeadlineKeepsSnapshotAndPermitUntilActualCompletionThenAllowsExplicitRetry() async throws {
        let image = try textImage(), frame = NativeDesktopTextFrame()
        frame.provider = .init(sourceID: "one", capture: { image })
        var pending: CheckedContinuation<SharedTextRecognitionResult, Never>?, calls = 0
        let selection = NativeDesktopSharedText(timeout: .milliseconds(40), recognition: { _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { pending = $0 } }
            return .transcript("fresh recognized text")
        })
        selection.updateSource(id: "one", name: "Alex", frame: frame); selection.open()
        try await wait { pending != nil }
        let capturedID = try XCTUnwrap(selection.snapshot?.id)
        try await wait { !selection.busy }
        XCTAssertEqual(selection.snapshot?.id, capturedID)
        XCTAssertEqual(selection.status, L("Text recognition is taking too long. Return to Live and try again later."))
        XCTAssertTrue(SharedTextWorkAdmission.shared.isOccupied); XCTAssertFalse(selection.canRefresh)
        selection.updateSource(id: "two", name: "Sam", frame: frame)
        XCTAssertEqual(selection.snapshot?.id, capturedID)
        selection.close()
        frame.provider = .init(sourceID: "two", capture: { image })
        selection.open()
        XCTAssertFalse(selection.busy); XCTAssertFalse(selection.canRefresh); XCTAssertNil(selection.snapshot)
        let reopenedStatus = selection.status
        pending?.resume(returning: .transcript("late stale text")); pending = nil
        try await wait { !SharedTextWorkAdmission.shared.isOccupied }
        XCTAssertNil(selection.snapshot); XCTAssertEqual(selection.transcript, ""); XCTAssertEqual(selection.status, reopenedStatus)
        XCTAssertTrue(selection.canRefresh)
        selection.refresh(); try await wait { !selection.busy }
        XCTAssertEqual(calls, 2); XCTAssertEqual(selection.transcript, "fresh recognized text")
        XCTAssertEqual(selection.snapshot?.sourceID, "two"); XCTAssertNotEqual(selection.snapshot?.id, capturedID)
        selection.close()
    }
    func testCaptureDeadlineAndMeetingExitRejectLateFrameWithoutHoldingModel() async throws {
        let image = try textImage(), frame = NativeDesktopTextFrame()
        var pending: CheckedContinuation<CGImage?, Never>?, recognitions = 0
        frame.provider = .init(sourceID: "one", capture: { await withCheckedContinuation { pending = $0 } })
        var selection: NativeDesktopSharedText? = NativeDesktopSharedText(timeout: .milliseconds(40), recognition: { _ in
            recognitions += 1; return .transcript("unexpected")
        })
        weak var owner = selection
        selection?.updateSource(id: "one", name: "Alex", frame: frame); selection?.open()
        try await wait { pending != nil }
        try await wait { selection?.busy == false }
        XCTAssertNil(selection?.snapshot)
        XCTAssertEqual(selection?.status, L("Text recognition is taking too long. Return to Live and try again later."))
        XCTAssertTrue(SharedTextWorkAdmission.shared.isOccupied)
        selection?.close(); selection = nil
        XCTAssertNil(owner, "A hanging system operation must not retain the meeting's UI model")
        pending?.resume(returning: image); pending = nil
        try await wait { !SharedTextWorkAdmission.shared.isOccupied }
        XCTAssertEqual(recognitions, 0)
    }
    func testDeadlineRejectsLateResultWhilePreviewRemainsOpen() async throws {
        let image = try textImage(), frame = NativeDesktopTextFrame()
        frame.provider = .init(sourceID: "one", capture: { image })
        var pending: CheckedContinuation<SharedTextRecognitionResult, Never>?
        let selection = NativeDesktopSharedText(timeout: .milliseconds(40), recognition: { _ in
            await withCheckedContinuation { pending = $0 }
        })
        selection.updateSource(id: "one", name: "Alex", frame: frame); selection.open()
        try await wait { pending != nil }
        try await wait { !selection.busy }
        let capturedID = selection.snapshot?.id, timeoutStatus = selection.status
        pending?.resume(returning: .transcript("late stale text")); pending = nil
        try await wait { !SharedTextWorkAdmission.shared.isOccupied }
        XCTAssertEqual(selection.snapshot?.id, capturedID); XCTAssertEqual(selection.transcript, "")
        XCTAssertEqual(selection.status, timeoutStatus); XCTAssertTrue(selection.canRefresh)
        selection.close()
    }
    private func textImage(_ text: String = "Release review\nCopy selected screen text") throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 6400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1600, height: 900).fill()
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 68), .foregroundColor: NSColor.black]).draw(at: NSPoint(x: 100, y: 450))
        return try XCTUnwrap(context.makeImage())
    }
    private func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}
