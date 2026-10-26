import AppKit
import CoreImage
import LiveKitWebRTC
import SwiftUI
import Vision
import VisionKit
import XCTest
@testable import RockNativeDesktop

@MainActor final class DesktopSharedTextTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try await wait(message: "Previous OCR framework work did not release admission within 20 seconds") {
            !SharedTextWorkAdmission.shared.isOccupied
        }
    }
    func testRecognitionAndCaptureRemainOwnedAfterSourceEnds() async throws {
        print("NATIVE_OCR_HOST case=english active=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow != nil) windows=\(NSApp.windows.count) visibleWindows=\(NSApp.windows.filter { $0.isVisible }.count) activationPolicy=\(NSApp.activationPolicy().rawValue)")
        let image = try textImage()
        let window = try await makeOCRWindow(image, kind: "english")
        let frame = NativeDesktopTextFrame(); frame.provider = .init(sourceID: "one", capture: { image })
        let selection = NativeDesktopSharedText()
        drainRealOCRAtTeardown(selection)
        selection.updateSource(id: "one", name: "Alex", frame: frame); selection.open()
        try await wait { !selection.busy }
        let snapshot = try XCTUnwrap(selection.snapshot)
        XCTAssertEqual(snapshot.image.width, 1600); XCTAssertEqual(snapshot.image.height, 900)
        if ImageAnalyzer.isSupported { XCTAssertTrue(selection.analysis?.hasResults(for: .text) == true) }
        else { XCTAssertFalse(selection.transcript.isEmpty) }
        let host = NSHostingView(rootView: NativeDesktopSharedTextView(model: selection))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 650)
        window.contentView = host
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        func findScroll(_ view: NSView) -> NativeDesktopTextScroll? {
            if let scroll = view as? NativeDesktopTextScroll { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        if ImageAnalyzer.isSupported {
        let scroll = try XCTUnwrap(findScroll(host))
        let retainedAnalysis = scroll.imageDocument.overlay.analysis
        scroll.setRelativeZoom(2)
        if #available(macOS 14.0, *), ImageAnalyzer.isSupported {
            let overlay = scroll.imageDocument.overlay
            try await wait { !overlay.text.isEmpty }
            let text = overlay.text, end = text.index(text.startIndex, offsetBy: min(7, text.count))
            overlay.selectedRanges = [text.startIndex..<end]
            let selected = overlay.selectedText
            XCTAssertFalse(selected.isEmpty)
            for size in [NSSize(width: 740, height: 900), NSSize(width: 1200, height: 520), NSSize(width: 1000, height: 650)] {
                window.setContentSize(size); host.layoutSubtreeIfNeeded()
                XCTAssertEqual(scroll.magnification, 2, accuracy: 0.001)
                XCTAssertTrue(scroll.imageDocument.overlay.analysis === retainedAnalysis)
                XCTAssertEqual(overlay.selectedText, selected, "Resizing must preserve the native Live Text selection")
                XCTAssertEqual(scroll.imageDocument.snapshotID, snapshot.id)
                XCTAssertTrue(scroll.documentVisibleRect.intersects(scroll.imageDocument.imageRect))
            }
            let visible = scroll.documentVisibleRect
            let emptyPoint = NSPoint(x: visible.midX, y: visible.minY + visible.height * 0.2)
            let location = scroll.imageDocument.convert(emptyPoint, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertFalse(overlay.hasActiveTextSelection, "Clicking empty image content clears selection without leaving the snapshot")
            XCTAssertTrue(selection.isOpen)
        }
        }
        if let scroll = findScroll(host) { scroll.setRelativeZoom(1) }
        if let seconds = Double(ProcessInfo.processInfo.environment["NATIVE_TEXT_RENDER_HOLD_SECONDS"] ?? ""), seconds.isFinite {
            try await Task.sleep(for: .seconds(min(60, max(0, seconds))))
        }
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let rendered = NSImage(size: host.bounds.size); rendered.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: rendered); attachment.name = "Native captured share with real Live Text overlay"; attachment.lifetime = .keepAlways; add(attachment)
        }
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
    func testNativeCopyActionFromRealTextSelectionInActiveWindow() async throws {
        guard #available(macOS 14.0, *), ImageAnalyzer.isSupported else { throw XCTSkip("Native selected-text inspection requires macOS 14 and Live Text support") }
        let image = try textImage(), frame = NativeDesktopTextFrame()
        let window = try await makeOCRWindow(image, kind: "copy")
        frame.provider = .init(sourceID: "copy", capture: { image })
        let selection = NativeDesktopSharedText(); defer { selection.close() }
        drainRealOCRAtTeardown(selection)
        selection.updateSource(id: "copy", name: "Synthetic copy source", frame: frame); selection.open()
        try await wait { !selection.busy }
        let host = NSHostingView(rootView: NativeDesktopSharedTextView(model: selection))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 650)
        window.contentView = host
        try await wait { window.isKeyWindow }
        host.layoutSubtreeIfNeeded()
        func findScroll(_ view: NSView) -> NativeDesktopTextScroll? {
            if let scroll = view as? NativeDesktopTextScroll { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        let scroll = try XCTUnwrap(findScroll(host)), overlay = scroll.imageDocument.overlay
        try await wait { !overlay.text.isEmpty }
        var point: NSPoint?
        for y in stride(from: overlay.bounds.maxY - 12, through: overlay.bounds.minY + 12, by: -12) {
            for x in stride(from: overlay.bounds.minX + 12, through: overlay.bounds.maxX - 12, by: 12) {
                let candidate = NSPoint(x: x, y: y)
                if overlay.analysisHasText(at: candidate) { point = candidate; break }
            }
            if point != nil { break }
        }
        let location = overlay.convert(try XCTUnwrap(point), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        try await wait { overlay.hasActiveTextSelection }
        let selected = overlay.selectedText; XCTAssertFalse(selected.isEmpty)
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } } ?? []
        defer {
            pasteboard.clearContents()
            let restored = saved.map { representations -> NSPasteboardItem in
                let item = NSPasteboardItem(); for (type, data) in representations { item.setData(data, forType: type) }; return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil))
        XCTAssertEqual(pasteboard.string(forType: .string), selected)
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
        print("NATIVE_OCR_HOST case=mixed active=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow != nil) windows=\(NSApp.windows.count) visibleWindows=\(NSApp.windows.filter { $0.isVisible }.count) activationPolicy=\(NSApp.activationPolicy().rawValue)")
        executionTimeAllowance = 75
        let image = try textImage("Release review\nПроверка текста")
        _ = try await makeOCRWindow(image, kind: "mixed")
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
        var captures = 0
        let frame = NativeDesktopTextFrame(); frame.provider = .init(sourceID: "mixed", capture: { captures += 1; return image })
        let selection = NativeDesktopSharedText(); defer { selection.close() }
        drainRealOCRAtTeardown(selection)
        selection.updateSource(id: "mixed", name: "Synthetic bilingual share", frame: frame); selection.open()
        try await finishRecognitionWithOneColdRetry(selection, captures: { captures })
        let transcript = selection.analysis?.transcript ?? selection.transcript
        XCTAssertTrue(transcript.contains("Release"), "Latin text missing: \(transcript)")
        XCTAssertTrue(transcript.contains("Проверка"), "Cyrillic text missing: \(transcript)")
    }
    func testColdRecognitionRetryWaitsForActualCompletionWithoutOverlappingCapture() async throws {
        let image = try textImage(), frame = NativeDesktopTextFrame()
        var captures = 0, recognitions = 0
        var pending: CheckedContinuation<SharedTextRecognitionResult, Never>?
        frame.provider = .init(sourceID: "cold", capture: { captures += 1; return image })
        let selection = NativeDesktopSharedText(timeout: .milliseconds(40), recognition: { _ in
            recognitions += 1
            if recognitions == 1 { return await withCheckedContinuation { pending = $0 } }
            return .transcript("Release Проверка")
        })
        defer { selection.close(); pending?.resume(returning: .transcript("cancelled fixture")) }
        selection.updateSource(id: "cold", name: "Synthetic cold recognition", frame: frame); selection.open()
        let completion = Task { @MainActor in
            try await wait { !selection.busy && pending != nil }
            XCTAssertTrue(SharedTextWorkAdmission.shared.isOccupied)
            XCTAssertFalse(selection.canRefresh)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(captures, 1, "The retry must wait for the actual recognition operation")
            pending?.resume(returning: .transcript("late stale result")); pending = nil
        }
        defer { completion.cancel() }
        try await finishRecognitionWithOneColdRetry(selection, captures: { captures })
        try await completion.value
        XCTAssertEqual(captures, 2); XCTAssertEqual(recognitions, 2)
        XCTAssertEqual(selection.transcript, "Release Проверка")
        XCTAssertFalse(SharedTextWorkAdmission.shared.isOccupied)
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
    func testZoomedResizeKeepsRetainedFrameAndReadingPositionVisible() throws {
        let image = try textImage()
        let snapshot = SharedTextSnapshot(image: image, sourceID: "share", sourceName: "Synthetic window")
        let scroll = NativeDesktopTextScroll(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        scroll.install(snapshot); scroll.layoutSubtreeIfNeeded()
        scroll.setRelativeZoom(3)
        let rect = scroll.imageDocument.imageRect, visible = scroll.documentVisibleRect.size
        scroll.contentView.scroll(to: NSPoint(x: rect.minX + rect.width * 0.46 - visible.width / 2,
                                             y: rect.minY + rect.height * 0.55 - visible.height / 2))
        let center = scroll.normalizedImageCenter
        for size in [NSSize(width: 600, height: 1000), NSSize(width: 1200, height: 500), NSSize(width: 800, height: 650)] {
            scroll.setFrameSize(size); scroll.layoutSubtreeIfNeeded()
            XCTAssertEqual(scroll.magnification, 3, accuracy: 0.001)
            let imageRect = scroll.imageDocument.imageRect, visibleSize = scroll.documentVisibleRect.size
            let minX = min(0.5, visibleSize.width / (2 * imageRect.width)), minY = min(0.5, visibleSize.height / (2 * imageRect.height))
            XCTAssertEqual(scroll.normalizedImageCenter.x, min(1 - minX, max(minX, center.x)), accuracy: 0.01)
            XCTAssertEqual(scroll.normalizedImageCenter.y, min(1 - minY, max(minY, center.y)), accuracy: 0.01)
            XCTAssertTrue(scroll.documentVisibleRect.intersects(scroll.imageDocument.imageRect), "Resizing must never scroll the frozen image out of the viewport")
            XCTAssertEqual(scroll.imageDocument.snapshotID, snapshot.id)
            XCTAssertEqual(scroll.imageDocument.image.image?.size, NSSize(width: 1600, height: 900))
        }
        scroll.setRelativeZoom(1)
        XCTAssertEqual(scroll.magnification, 1)
        XCTAssertEqual(scroll.normalizedImageCenter.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(scroll.normalizedImageCenter.y, 0.5, accuracy: 0.001)
    }
    func testExtremeMagnifiedPanCannotEnterLetterboxAndEdgePositionReturnsAfterResize() throws {
        let image = try textImage()
        let snapshot = SharedTextSnapshot(image: image, sourceID: "share", sourceName: "Alex")
        let scroll = NativeDesktopTextScroll(frame: NSRect(x: 0, y: 0, width: 1200, height: 500))
        scroll.install(snapshot); scroll.layoutSubtreeIfNeeded(); scroll.setRelativeZoom(3)
        let rect = scroll.imageDocument.imageRect, visible = scroll.documentVisibleRect
        let proposed = CGRect(x: rect.midX - visible.width / 2, y: rect.maxY - visible.height, width: visible.width, height: visible.height)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposed).origin)
        let edge = scroll.normalizedImageCenter
        XCTAssertGreaterThan(edge.y, 0.8)
        scroll.setFrameSize(NSSize(width: 600, height: 1000)); scroll.layoutSubtreeIfNeeded()
        XCTAssertLessThan(scroll.normalizedImageCenter.y, edge.y)
        scroll.setFrameSize(.zero); scroll.layoutSubtreeIfNeeded()
        scroll.setFrameSize(NSSize(width: 1200, height: 500)); scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.normalizedImageCenter.y, edge.y, accuracy: 0.01)
        XCTAssertEqual(scroll.imageDocument.snapshotID, snapshot.id)
        for size in [NSSize(width: 600, height: 1000), NSSize(width: 1200, height: 500)] {
            scroll.setFrameSize(size); scroll.layoutSubtreeIfNeeded(); scroll.setRelativeZoom(8)
            let visibleSize = scroll.documentVisibleRect.size
            for point in [NSPoint(x: -10000, y: -10000), NSPoint(x: 10000, y: 10000)] {
                let requested = CGRect(origin: point, size: visibleSize)
                let allowed = scroll.contentView.constrainBoundsRect(requested)
                scroll.contentView.scroll(to: allowed.origin)
                let intersection = scroll.documentVisibleRect.intersection(scroll.imageDocument.imageRect)
                XCTAssertEqual(intersection.width, visibleSize.width, accuracy: 0.01)
                XCTAssertEqual(intersection.height, visibleSize.height, accuracy: 0.01)
            }
        }
    }
    func testNewFrameKeepsSameSourceViewportButReplacementStartsAtFit() throws {
        let image = try textImage()
        let scroll = NativeDesktopTextScroll(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let first = SharedTextSnapshot(image: image, sourceID: "one", sourceName: "Alex")
        scroll.install(first); scroll.layoutSubtreeIfNeeded(); scroll.setRelativeZoom(2)
        let center = scroll.normalizedImageCenter
        let refreshed = SharedTextSnapshot(image: image, sourceID: "one", sourceName: "Alex")
        scroll.install(refreshed); scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.magnification, 2)
        XCTAssertEqual(scroll.normalizedImageCenter.x, center.x, accuracy: 0.001)
        XCTAssertEqual(scroll.normalizedImageCenter.y, center.y, accuracy: 0.001)
        XCTAssertEqual(scroll.imageDocument.snapshotID, refreshed.id)
        let replacement = SharedTextSnapshot(image: image, sourceID: "two", sourceName: "Sam")
        scroll.install(replacement); scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.magnification, 1)
        XCTAssertEqual(scroll.normalizedImageCenter.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(scroll.normalizedImageCenter.y, 0.5, accuracy: 0.001)
    }
    func testCapturedImageInheritsLiveZoomAndPanWithoutLosingPixels() throws {
        let image = try textImage()
        let scroll = NativeDesktopTextScroll(frame: NSRect(x: 0, y: 0, width: 1200, height: 750))
        let snapshot = SharedTextSnapshot(image: image, sourceID: "one", sourceName: "Alex")
        let oldSize = CGSize(width: 900, height: 600), pan = CGSize(width: 0.3, height: -0.2)
        let expected = NativeDesktopTextScroll.initialCenter(imageSize: CGSize(width: 1600, height: 900), viewportSize: oldSize, zoom: 2, pan: pan)
        scroll.install(snapshot, initialZoom: 2, initialPan: pan, initialViewportSize: oldSize)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.magnification, 2)
        XCTAssertEqual(scroll.normalizedImageCenter.x, expected.x, accuracy: 0.01)
        XCTAssertEqual(scroll.normalizedImageCenter.y, expected.y, accuracy: 0.01)
        XCTAssertEqual(scroll.imageDocument.image.image?.size, NSSize(width: 1600, height: 900))
    }
    func testHostedCapturedFrameSurvivesRepeatedWindowResizeWithoutRecapture() async throws {
        let image = try textImage(), frame = NativeDesktopTextFrame()
        var captures = 0
        frame.provider = .init(sourceID: "one", capture: { captures += 1; return image })
        let selection = NativeDesktopSharedText(recognition: { _ in .transcript("") }); defer { selection.close() }
        selection.updateSource(id: "one", name: "Alex", frame: frame); selection.open()
        try await wait { !selection.busy }
        let snapshot = try XCTUnwrap(selection.snapshot)
        let host = NSHostingView(rootView: NativeDesktopSharedTextView(model: selection))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 650)
        host.layoutSubtreeIfNeeded()
        func findScroll(_ view: NSView) -> NativeDesktopTextScroll? {
            if let scroll = view as? NativeDesktopTextScroll { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        let scroll = try XCTUnwrap(findScroll(host))
        scroll.setRelativeZoom(2)
        for size in [NSSize(width: 740, height: 900), NSSize(width: 1240, height: 520), NSSize(width: 1000, height: 650)] {
            host.setFrameSize(size); host.layoutSubtreeIfNeeded()
            XCTAssertEqual(scroll.magnification, 2, accuracy: 0.001)
            XCTAssertTrue(scroll.documentVisibleRect.intersects(scroll.imageDocument.imageRect))
            XCTAssertEqual(scroll.imageDocument.snapshotID, snapshot.id)
        }
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(selection.snapshot?.id, snapshot.id)
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
        XCTAssertNil(selection.snapshot); XCTAssertTrue(selection.statusNeedsAttention)
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
        XCTAssertTrue(selection.statusNeedsAttention)
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
    private func makeOCRWindow(_ image: CGImage, kind: String) async throws -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: 1000, height: 650)
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Synthetic OCR validation (\(kind))"
        let preview = NSImageView(frame: rect)
        preview.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        preview.imageScaling = .scaleProportionallyUpOrDown
        window.contentView = preview
        // XCTest runs teardown blocks last-in-first-out. The later OCR drain
        // finishes before this window closes, including when the test throws.
        addTeardownBlock { @MainActor in window.orderOut(nil); window.close(); window.contentView = nil }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait(message: "OCR fixture did not obtain an active key window within 20 seconds") {
            NSApp.isActive && window.isKeyWindow && window.isVisible
        }
        print("NATIVE_OCR_FIXTURE case=\(kind) active=\(NSApp.isActive) keyWindow=\(window.isKeyWindow) visible=\(window.isVisible)")
        return window
    }
    private func drainRealOCRAtTeardown(_ selection: NativeDesktopSharedText) {
        addTeardownBlock { @MainActor in
            selection.close()
            try await self.wait(message: "OCR framework work remained active after bounded teardown") {
                !SharedTextWorkAdmission.shared.isOccupied
            }
        }
    }
    private func finishRecognitionWithOneColdRetry(_ selection: NativeDesktopSharedText,
                                                  captures: () -> Int) async throws {
        try await wait { !selection.busy }
        guard selection.status == L("Text recognition is taking too long. Return to Live and try again later.") else { return }
        let snapshot = try XCTUnwrap(selection.snapshot)
        let initialCaptures = captures()
        XCTAssertTrue(selection.isOpen); XCTAssertTrue(selection.statusNeedsAttention)
        XCTAssertEqual(snapshot.image.width, 1600); XCTAssertEqual(snapshot.image.height, 900)
        if SharedTextWorkAdmission.shared.isOccupied { XCTAssertFalse(selection.canRefresh) }
        try await wait(message: "Timed-out system recognition did not actually finish within 20 seconds") {
            !SharedTextWorkAdmission.shared.isOccupied
        }
        XCTAssertEqual(selection.snapshot?.id, snapshot.id)
        XCTAssertNil(selection.analysis); XCTAssertEqual(selection.transcript, "")
        XCTAssertEqual(captures(), initialCaptures, "Admission release must not trigger an implicit recapture")
        try await wait { selection.canRefresh }
        let attachment = XCTAttachment(string: "Cold OCR reached its UI deadline; retained snapshot and admission were preserved. Actual framework work completed before one explicit New frame retry.")
        attachment.name = "Bounded cold OCR retry"; attachment.lifetime = .keepAlways; add(attachment)
        selection.refresh()
        XCTAssertTrue(SharedTextWorkAdmission.shared.isOccupied)
        try await wait { !selection.busy }
        XCTAssertEqual(captures(), initialCaptures + 1)
        XCTAssertNotEqual(selection.snapshot?.id, snapshot.id)
        guard selection.status != L("Text recognition is taking too long. Return to Live and try again later.") else {
            XCTFail("A second timeout fails acceptance; the test must not loop or reset admission")
            throw WaitFailure.deadline
        }
    }
    private enum WaitFailure: Error { case deadline }
    private func wait(message: String = "Condition did not become true within 20 seconds",
                      file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { XCTFail(message, file: file, line: line); throw WaitFailure.deadline }
    }
}
