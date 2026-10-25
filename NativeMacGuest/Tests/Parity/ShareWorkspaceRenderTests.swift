import AppKit
import SwiftUI
import XCTest
@testable import RockNativeDesktop

@MainActor final class ShareWorkspaceRenderTests: XCTestCase {
    func testPrivateWorkspaceAtCompactAndWideDesktopSizes() async throws {
        let suite = "ShareRender.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = NativeDesktopPresenterSession(factory: { nil }, liveCamera: { nil },
            publish: { _, _ in XCTFail("Rendering private controls must not publish") }, unpublish: {}, preferences: preferences)
        session.supportsVP9 = true
        for size in [NSSize(width: 860, height: 600), NSSize(width: 1100, height: 760)] {
            let host = NSHostingView(rootView: NativeDesktopPresenterEditor(session: session))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; defer { window.close() }
            window.title = "Private Share workspace validation"; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = NSImage(size: size); image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Private unified Share workspace \(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways; add(attachment)
            if ProcessInfo.processInfo.environment["NATIVE_SHARE_RENDER_HOLD"] == "1" { try await Task.sleep(for: .seconds(25)) }
        }
        XCTAssertFalse(session.includeCamera); XCTAssertFalse(session.isSharing)
        XCTAssertNil(session.contentDraft)
        _ = await session.close()
    }
}
