#if NATIVE_DIRECT_UPDATES
import AppKit
import SwiftUI
import XCTest
@testable import RockNativeDesktop

private struct SupportLayoutProbe: View {
    @Environment(\.layoutDirection) var direction
    let report: (LayoutDirection) -> Void
    var body: some View { Color.clear.onAppear { report(direction) } }
}

@MainActor final class AuthorSupportPresentationTests: XCTestCase {
    /// Use xcodebuild -testLanguage ar -testRegion SA (or ru/RU, es/ES) to
    /// exercise the app bundle's language selection in a separate host process.
    func testLocalizedSupportSettingsSnapshot() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let requested = env["NATIVE_AUTHOR_SUPPORT_SCREEN"] else {
            throw XCTSkip("Select an app language to capture a native support screen.")
        }
        XCTAssertEqual(SupportCopy.language, requested)
        var renderedDirection: LayoutDirection?
        let view = NativeDesktopSettingsView(library: NativeDesktopLibrary(), meeting: nil, tab: .constant(SupportCopy.settingsTab))
            .background(SupportLayoutProbe { renderedDirection = $0 })
            .frame(width: 950, height: 700)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 950, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(renderedDirection, requested == "ar" ? .rightToLeft : .leftToRight)
        let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 8_000)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "Support Settings - " + requested
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSeventhDistinctUseDayAndMonthlyVisibleImpressionSurviveRelaunch() throws {
        let suite = "support.reminder.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tz = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        func date(_ text: String) throws -> Date {
            try XCTUnwrap(ISO8601DateFormatter().date(from: text + "T12:00:00Z"))
        }
        let history = SupportReminder(defaults: defaults)
        for day in ["2026-10-01","2026-10-03","2026-10-08","2026-11-02","2026-11-03","2026-11-15"] {
            let used = try date(day)
            history.recordUse(at: used, timeZone: tz)
            history.recordUse(at: used, timeZone: tz)
            XCTAssertFalse(history.eligible(active: false, at: used, timeZone: tz))
        }
        let seventh = try date("2026-11-19")
        history.recordUse(at: seventh, timeZone: tz)
        XCTAssertFalse(history.claimVisible(active: true, at: seventh, timeZone: tz))
        XCTAssertTrue(history.eligible(active: false, at: seventh, timeZone: tz))
        let secondWindow = SupportReminder(defaults: defaults)
        XCTAssertTrue(secondWindow.claimVisible(active: false, at: seventh, timeZone: tz))
        XCTAssertFalse(history.claimVisible(active: false, at: try date("2026-11-30"), timeZone: tz))
        XCTAssertFalse(history.claimVisible(active: false, at: try date("2026-10-31"), timeZone: tz))
        let renewal = try date("2026-12-01")
        XCTAssertFalse(secondWindow.eligible(active: true, at: renewal, timeZone: tz))
        XCTAssertTrue(secondWindow.claimVisible(active: false, at: renewal, timeZone: tz))
        XCTAssertFalse(secondWindow.claimVisible(active: false, at: renewal, timeZone: tz))
        XCTAssertTrue(history.claimVisible(active: false, at: try date("2027-02-01"), timeZone: tz))
    }

    func testPackagedSupportTablesAndFormatArgumentsMatchInAllNineLanguages() throws {
        let bundle = try XCTUnwrap(SupportCopy.bundle)
        func values(_ language: String) throws -> [String: String] {
            let url = try XCTUnwrap(bundle.url(forResource: "AuthorSupport", withExtension: "strings", subdirectory: nil, localization: language))
            let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            return try XCTUnwrap(value as? [String: String])
        }
        let originals = try values("en")
        let tokens = try NSRegularExpression(pattern: #"%([0-9]+\$)?@"#)
        func arguments(_ text: String) -> [String] {
            tokens.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } }.sorted()
        }
        for language in ["ru","es","fr","ar","hi","de","zh-Hans","id"] {
            let strings = try values(language)
            XCTAssertEqual(Set(strings.keys), Set(originals.keys), language)
            for (key, source) in originals {
                let translated = try XCTUnwrap(strings[key])
                XCTAssertFalse(translated.isEmpty, key)
                XCTAssertNotEqual(source, translated, "\(language) \(key)")
                XCTAssertEqual(arguments(source), arguments(translated), "\(language) \(key)")
            }
        }
    }
}
#endif
