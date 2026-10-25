import XCTest
import SwiftUI
@testable import RockNRoll

@MainActor final class NativeMacRecommendationTests: XCTestCase {
    func testOnlyIdleCompatibilityHostOffersNotice() {
        let suite = "NativeMacRecommendationTests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let mac = NativeMacRecommendation(isSupportedHost: true, preferences: preferences)
        XCTAssertTrue(mac.showsNotice(isIdle: true))
        XCTAssertFalse(mac.showsNotice(isIdle: false), "Joining, active/hidden meetings, leaving and transfer must stay uninterrupted")
        let mobile = NativeMacRecommendation(isSupportedHost: false, preferences: preferences)
        XCTAssertFalse(mobile.showsNotice(isIdle: true)); XCTAssertFalse(mobile.showsNotice(isIdle: false))
    }
    func testDismissalSurvivesRelaunchAndDoesNotDisableSettingsOrModifyMeetingPreferences() {
        let suite = "NativeMacRecommendationTests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("Alex", forKey: "savedDisplayName"); preferences.set(true, forKey: "calendar.automaticJoin")
        let first = NativeMacRecommendation(isSupportedHost: true, preferences: preferences)
        first.dismiss()
        let restored = NativeMacRecommendation(isSupportedHost: true, preferences: preferences)
        XCTAssertTrue(restored.dismissed); XCTAssertFalse(restored.showsNotice(isIdle: true))
        XCTAssertTrue(restored.isSupportedHost, "Settings discovery remains available")
        XCTAssertEqual(preferences.string(forKey: "savedDisplayName"), "Alex")
        XCTAssertTrue(preferences.bool(forKey: "calendar.automaticJoin"))
    }
    func testOpeningOfficialLandingDoesNotDismissOrInstall() {
        let suite = "NativeMacRecommendationTests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let recommendation = NativeMacRecommendation(isSupportedHost: true, preferences: preferences)
        var opened: [URL] = []
        recommendation.visitDownloadPage { opened.append($0) }
        XCTAssertEqual(opened.map(\.absoluteString), ["https://rock.glowsoft.ru/#download"])
        XCTAssertFalse(recommendation.dismissed)
        XCTAssertNil(preferences.object(forKey: NativeMacRecommendation.dismissedKey))
        NativeMacRecommendation(isSupportedHost: false, preferences: preferences).visitDownloadPage { opened.append($0) }
        XCTAssertEqual(opened.count, 1)
    }
    func testMeetingActivitySuppressesReinsertionForThisLaunchWithoutPersistingDismissal() {
        let suite = "NativeMacRecommendationTests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let recommendation = NativeMacRecommendation(isSupportedHost: true, preferences: preferences)
        recommendation.observeMeetingActivity(false)
        XCTAssertTrue(recommendation.showsNotice(isIdle: true))
        recommendation.observeMeetingActivity(true)
        recommendation.observeMeetingActivity(false)
        XCTAssertFalse(recommendation.showsNotice(isIdle: true), "A failed join must not insert a row under an existing pointer")
        XCTAssertTrue(recommendation.isSupportedHost)
        XCTAssertNil(preferences.object(forKey: NativeMacRecommendation.dismissedKey))
        XCTAssertTrue(NativeMacRecommendation(isSupportedHost: true, preferences: preferences).showsNotice(isIdle: true))
    }
    func testCurrentHostMatchesPublicRuntimeDetection() {
        XCTAssertEqual(NativeMacRecommendation.current().isSupportedHost, ProcessInfo.processInfo.isiOSAppOnMac)
    }
    func testDismissalIsLocalToThisPreferenceStore() {
        let names = (0..<2).map { _ in "NativeMacRecommendationTests." + UUID().uuidString }
        let stores = names.map { UserDefaults(suiteName: $0)! }
        defer { for (name, store) in zip(names, stores) { store.removePersistentDomain(forName: name) } }
        NativeMacRecommendation(isSupportedHost: true, preferences: stores[0]).dismiss()
        XCTAssertTrue(NativeMacRecommendation(isSupportedHost: true, preferences: stores[1]).showsNotice(isIdle: true))
    }
    func testRenderingOnActualMacCompatibilityHost() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { throw XCTSkip("Actual Mac compatibility host only") }
        let suite = "NativeMacRecommendationTests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let recommendation = NativeMacRecommendation(preferences: preferences)
        XCTAssertTrue(recommendation.isSupportedHost)
        XCTAssertTrue(recommendation.showsNotice(isIdle: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow))
        let original = window.rootViewController
        defer { window.rootViewController = original }
        let host = UIHostingController(rootView: Form {
            Section { NativeMacRecommendationCard(recommendation: recommendation, getApp: {}) }
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.bounds.width, 400)
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Actual Mac compatibility host recommendation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
