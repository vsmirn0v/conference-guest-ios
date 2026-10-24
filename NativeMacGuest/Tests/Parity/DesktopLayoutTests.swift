import AppKit
import ConferenceCore
import CoreText
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// Opt in with NATIVE_DESKTOP_LAYOUT_FIXTURE=1. The optional hold interval is
/// clamped to 120 seconds so CUA can inspect the real meeting window.
@MainActor final class DesktopLayoutTests: XCTestCase {
    func testOfflineMeetingLayoutFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NATIVE_DESKTOP_LAYOUT_FIXTURE"] == "1" || environment["NATIVE_DESKTOP_LAYOUT_HOLD_SECONDS"] != nil else {
            throw XCTSkip("Set NATIVE_DESKTOP_LAYOUT_FIXTURE=1 or NATIVE_DESKTOP_LAYOUT_HOLD_SECONDS to show the offline layout fixture.")
        }
        let requested = Double(environment["NATIVE_DESKTOP_LAYOUT_HOLD_SECONDS"] ?? "0") ?? 0
        let hold = requested.isFinite ? min(120, max(0, requested)) : 0
        let autosaveKey = "NSWindow Frame nativeDesktop.meeting"
        let savedFrame = UserDefaults.standard.object(forKey: autosaveKey)
        let catchUpURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catch-up.json")
        let savedCatchUp = try [catchUpURL, catchUpURL.appendingPathExtension("session")].map { url in
            (url, FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil)
        }
        defer {
            if let savedFrame { UserDefaults.standard.set(savedFrame, forKey: autosaveKey) }
            else { UserDefaults.standard.removeObject(forKey: autosaveKey) }
            for (url, data) in savedCatchUp {
                do {
                    if let data { try data.write(to: url, options: .atomic) }
                    else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                } catch { XCTFail("Could not restore fixture catch-up state: \(error)") }
            }
        }
        let engine = await OfflineLayoutEngine.make()
        let title = "Desktop Layout Fixture · 11 participants"
        let model = NativeDesktopMeetingModel(destination: try .verified(URL(string: "https://layout.invalid/calls/offline-layout")!, engine: .guest),
            name: "Local Layout Participant", title: title, engine: engine)
        model.viewMode = .gallery
        let window = NativeDesktopMeetingWindow(model: model)
        model.onLeave = { [weak model, weak window] in
            _ = await model?.leave(); window?.close()
        }
        do {
            // Publish only the injected engine's state. model.connect() installs the
            // real headset integration, which this visual fixture does not need.
            try await engine.connect(invitation: model.invitation, name: model.displayName, quiet: false)
            model.chat.canSend = true
            model.chat.onSend = { [weak model] text in
                guard let model else { return }
                model.chat.append(.init(id: UUID().uuidString, sender: "Local Layout Participant", text: text,
                    sentAt: Date(), isOwn: true))
                model.chat.draft = ""
            }
            for index in 0..<8 {
                model.chat.append(.init(id: "layout-message-\(index)", sender: engine.people[(index + 1) % engine.people.count].name,
                    text: index.isMultiple(of: 2) ? "Layout fixture message with enough text to wrap naturally in the conversation inspector." : "The shared canvas is generated in memory.",
                    sentAt: Date().addingTimeInterval(Double(index - 8) * 30), isOwn: false))
            }
            window.show()
            let nativeWindow = try XCTUnwrap(NSApp.windows.first { $0.title == title })
            nativeWindow.identifier = NSUserInterfaceItemIdentifier("native.desktop.layout.fixture")
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                let requestedWidth = Double(environment["NATIVE_DESKTOP_LAYOUT_WIDTH"] ?? "1240") ?? 1240
                let requestedHeight = Double(environment["NATIVE_DESKTOP_LAYOUT_HEIGHT"] ?? "800") ?? 800
                let width = min(max(740, requestedWidth.isFinite ? requestedWidth : 1240), visible.width - 40)
                let height = min(max(540, requestedHeight.isFinite ? requestedHeight : 800), visible.height - 40)
                nativeWindow.setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                    width: width, height: height), display: true)
            }
            try await Task.sleep(for: .milliseconds(700))
            XCTAssertEqual(model.participants.count, 11)
            XCTAssertEqual(model.galleryPages, 2)
            XCTAssertGreaterThanOrEqual(engine.people.filter { $0.name.count > 55 }.count, 6)
            XCTAssertEqual(engine.people.filter { $0.sharing == true }.count, 2)
            XCTAssertEqual(engine.networkRequests, 0); XCTAssertEqual(engine.physicalCaptureRequests, 0)
            XCTAssertGreaterThan(engine.patterns.first?.frames ?? 0, 0)
            let guide = guide(title: title, nativeWindow: nativeWindow, hold: hold)
            let data = try JSONSerialization.data(withJSONObject: guide, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Offline desktop layout fixture guide"; attachment.lifetime = .keepAlways; add(attachment)
            print("NATIVE_DESKTOP_LAYOUT_READY " + String(data: data, encoding: .utf8)!)
            let end = Date().addingTimeInterval(hold)
            while Date() < end, model.snapshot.phase != .left {
                try await Task.sleep(for: .milliseconds(100))
            }
            evidence(model, engine: engine)
            let clean = await model.leave()
            XCTAssertTrue(clean); XCTAssertEqual(engine.networkRequests, 0); XCTAssertEqual(engine.physicalCaptureRequests, 0)
            window.close(); model.onLeave = nil
        } catch {
            _ = await model.leave(); window.close(); model.onLeave = nil; throw error
        }
    }
    private func guide(title: String, nativeWindow: NSWindow, hold: Double) -> [String: Any] {
        let content = nativeWindow.contentView?.bounds.size ?? nativeWindow.frame.size
        let main = NSScreen.screens.first?.frame ?? .zero
        return ["windowTitle": title, "windowIdentifier": "native.desktop.layout.fixture", "holdSeconds": hold,
            "participants": 11, "galleryPages": 2,
            "longNames": 6, "sharedCanvases": 2, "network": false, "physicalCamera": false, "physicalMicrophone": false,
            "frameTopLeftPoints": [nativeWindow.frame.minX, main.maxY - nativeWindow.frame.maxY, nativeWindow.frame.width, nativeWindow.frame.height],
            "contentSizePoints": [content.width, content.height], "backingScaleFactor": nativeWindow.backingScaleFactor,
            "controls": ["participants": L("Participants"), "conversation": L("Conversation"), "mini": L("Mini meeting"),
                "restore": L("Show meeting"), "view": L("Gallery"), "more": L("More"), "focus": L("Focus"),
                "cameraFocus": L("Focus camera"), "screenFocus": L("Focus screen"), "leave": L("Leave")],
            "sharingNames": OfflineLayoutEngine.names.enumerated().filter { [3, 8].contains($0.offset) }.map(\.element),
            "guide": ["Gallery starts with six tiles per page; the two chevron buttons beside the view menu change page.",
                "Participants, Conversation and Mini meeting are in the upper-right capsule.",
                "The bottom view menu contains Gallery, Focus, Audio only and both screen-sharing participants.",
                "More opens Camera & sound and Presenter; no hardware is connected by the fake engine.",
                "Mini meeting hides the main window; Show meeting restores it.",
                "Resizing below 1040 points changes the inspector from a side column to a sheet."]]
    }
    private func evidence(_ model: NativeDesktopMeetingModel, engine: OfflineLayoutEngine) {
        print("NATIVE_DESKTOP_LAYOUT_FINISHED mode=\(model.viewMode.rawValue) page=\(model.galleryPage + 1) panel=\(model.panel?.rawValue ?? "none") participants=\(model.participants.count) demands=\(engine.demandChanges) frames=\(engine.patterns.map(\.frames))")
    }
}

@MainActor private final class OfflineLayoutEngine: NativeDesktopMeetingEngine {
    static let names = ["Local Layout Participant",
        "Alexandra Montgomery-Wellington — Customer Infrastructure and Reliability",
        "Christopher Alexander Bennett-Livingston — European Design Review",
        "Priyanka Ramanathan Subramanian — Platform Integration Workstream",
        "María Fernanda Rodríguez de la Torre — Enterprise Customer Delivery",
        "Konstantinos Papadopoulos Georgiou — Distributed Service Operations",
        "Samantha Elizabeth MacAllister-Johnson — Conference Moderator",
        "Noah Li", "Yuki Tanaka", "Omar Hassan", "Elena Petrova"]
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var factory: LKRTCPeerConnectionFactory? { nil }
    var privateAudioLevel: Float? { snapshot.phase == .connected ? 0.42 : nil }
    private(set) var snapshot = NativeDesktopExternalSnapshot()
    private(set) var incomingVideo: [NativeDesktopExternalVideo] = []
    let patterns: [OfflineLayoutPattern]
    let people: [NativeDesktopParticipant]
    let networkRequests = 0
    let physicalCaptureRequests = 0
    private(set) var demandChanges = 0
    private var visible: Set<String>?
    private var focused: String?
    private let allVideos: [NativeDesktopExternalVideo]
    private init(patterns: [OfflineLayoutPattern]) {
        self.patterns = patterns
        people = Self.names.enumerated().map { index, name in
            .init(id: "layout-person-\(index)", name: name, isLocal: index == 0,
                microphoneOn: index != 0 && index.isMultiple(of: 3), cameraOn: true, sharing: [3, 8].contains(index), speaking: index == 2)
        }
        var videos = people.filter { !$0.isLocal }.map { person in
            NativeDesktopExternalVideo(id: person.id + ".camera", participantID: person.id, source: .camera, track: patterns[0].track)
        }
        videos.append(.init(id: "layout-screen-landscape", participantID: "layout-person-3", source: .screen, track: patterns[1].track))
        videos.append(.init(id: "layout-screen-portrait", participantID: "layout-person-8", source: .screen, track: patterns[2].track))
        allVideos = videos
    }
    static func make() async -> OfflineLayoutEngine {
        let patterns = await Task.detached {
            let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
            return [OfflineLayoutPattern(factory: factory, width: 640, height: 400, title: "OFFLINE PARTICIPANT", hue: 0.60),
                OfflineLayoutPattern(factory: factory, width: 1280, height: 800, title: "LAYOUT REVIEW · SHARED CANVAS", hue: 0.09),
                OfflineLayoutPattern(factory: factory, width: 800, height: 1200, title: "PORTRAIT SHARED CANVAS", hue: 0.42)]
        }.value
        return .init(patterns: patterns)
    }
    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        patterns.forEach { $0.start() }
        snapshot = .init(phase: .connected, microphoneOn: false, cameraOn: true, playoutOn: !quiet,
            participants: people, microphoneLevel: 0.18)
        onState?(snapshot); onLocalCamera?(patterns[0].track); publishVideo()
    }
    func reconnect() async throws { snapshot.phase = .connected; onState?(snapshot) }
    func setMicrophone(_ enabled: Bool) async throws { snapshot.microphoneOn = enabled; onState?(snapshot) }
    func setCamera(_ enabled: Bool) async throws {
        snapshot.cameraOn = enabled; onState?(snapshot)
        // Keep the synthetic private preview available; no real preview can start.
        onLocalCamera?(patterns[0].track)
    }
    func setPlayout(_ enabled: Bool) async throws { snapshot.playoutOn = enabled; onState?(snapshot) }
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws { snapshot.sharing = track != nil; onState?(snapshot) }
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws {
        visible = ids; focused = focusedParticipantID; demandChanges += 1; publishVideo()
    }
    func startPrivateAudioCheck() async throws {}
    func stopPrivateAudioCheck() async throws {}
    func leave() async -> Bool {
        guard snapshot.phase != .left else { return true }
        for pattern in patterns { await pattern.stop() }
        incomingVideo = []; onVideo?([]); onLocalCamera?(nil)
        snapshot.phase = .left; snapshot.cameraOn = false; snapshot.microphoneOn = false; onState?(snapshot)
        return true
    }
    private func publishVideo() {
        incomingVideo = allVideos.filter { visible == nil || visible!.contains($0.participantID) || focused == $0.participantID }
        onVideo?(incomingVideo)
    }
}

/// Three fixed-size producer slots run at 10fps, with a four-buffer pool each.
/// No peer connection, audio track, device enumeration or capture session exists.
private final class OfflineLayoutPattern: @unchecked Sendable {
    let track: LKRTCVideoTrack
    private let factory: LKRTCPeerConnectionFactory
    private let source: LKRTCVideoSource
    private let capturer: LKRTCVideoCapturer
    private let queue = DispatchQueue(label: "desktop-layout.pattern", qos: .userInitiated)
    private let countLock = NSLock()
    private var count = 0
    var frames: Int { countLock.lock(); defer { countLock.unlock() }; return count }
    private let width: Int
    private let height: Int
    private let title: String
    private let hue: CGFloat
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    init(factory: LKRTCPeerConnectionFactory, width: Int, height: Int, title: String, hue: CGFloat) {
        self.factory = factory; self.width = width; self.height = height; self.title = title; self.hue = hue
        source = factory.videoSource(forScreenCast: true); capturer = LKRTCVideoCapturer(delegate: source)
        track = factory.videoTrack(with: source, trackId: "layout-pattern-" + UUID().uuidString)
        source.adaptOutputFormat(toWidth: Int32(width), height: Int32(height), fps: 10)
    }
    func start() {
        queue.async {
            guard self.timer == nil else { return }
            let fields: [CFString: Any] = [kCVPixelBufferWidthKey: self.width, kCVPixelBufferHeightKey: self.height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            guard CVPixelBufferPoolCreate(nil, nil, fields as CFDictionary, &self.pool) == kCVReturnSuccess else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(5))
            timer.setEventHandler { [weak producer = self] in producer?.frame() }; self.timer = timer; timer.resume()
        }
    }
    private func frame() {
        var pixels: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary, &pixels) == kCVReturnSuccess, let pixels else { return }
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels), let context = CGContext(data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) {
            context.setFillColor(NSColor(calibratedHue: hue, saturation: 0.42, brightness: 0.19, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let inset = CGFloat(min(width, height)) * 0.08
            context.setFillColor(NSColor(calibratedHue: hue, saturation: 0.4, brightness: 0.38, alpha: 1).cgColor)
            context.fill(CGRect(x: inset, y: inset, width: CGFloat(width) - inset * 2, height: CGFloat(height) - inset * 2))
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(min(width, height)) * 0.042, nil)
            let text = NSAttributedString(string: title, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.cgColor])
            context.textPosition = CGPoint(x: inset * 1.35, y: CGFloat(height) - inset * 1.7)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
            for row in 0..<5 { context.fill(CGRect(x: inset * 1.35, y: inset * 1.5 + CGFloat(row) * inset,
                width: (CGFloat(width) - inset * 2.7) * (row.isMultiple(of: 2) ? 0.85 : 0.65), height: inset * 0.23)) }
            let offset = CGFloat(count % 40) / 40 * (CGFloat(width) - inset * 3)
            context.setFillColor(NSColor.systemOrange.cgColor)
            context.fill(CGRect(x: inset * 1.35 + offset, y: inset * 0.6, width: inset * 0.4, height: inset * 0.3))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        countLock.lock(); count += 1; countLock.unlock()
        source.capturer(capturer, didCapture: LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0,
            timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1e9)))
    }
    func stop() async {
        await withCheckedContinuation { continuation in queue.async {
            self.timer?.cancel(); self.timer = nil; self.pool = nil; continuation.resume()
        } }
    }
}
