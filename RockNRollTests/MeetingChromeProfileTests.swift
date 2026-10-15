import Darwin
import UIKit
import XCTest
@testable import RockNRoll

/// Opt-in comparison of the same moving-video fixture with glass or solid chrome.
/// App CPU and main-thread scheduling are proxies; they do not measure battery energy.
@MainActor
final class MeetingChromeProfileTests: XCTestCase {
    func testOptInVisibleMeetingChromeProfile() async throws {
        guard ProcessInfo.processInfo.environment["MEETING_CHROME_VISIBLE_PROFILE"] == "1" else {
            throw XCTSkip("Opt-in visible chrome comparison")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let fixture = GuestCallLayoutFixture()
        window.rootViewController = fixture; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        var before = rusage(), after = rusage()
        getrusage(RUSAGE_SELF, &before)
        let began = ProcessInfo.processInfo.systemUptime
        var previousTick = began, worstTick: TimeInterval = 0
        while ProcessInfo.processInfo.systemUptime - began < 20 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let now = ProcessInfo.processInfo.systemUptime
            worstTick = max(worstTick, now - previousTick)
            previousTick = now
        }
        getrusage(RUSAGE_SELF, &after)
        func cpu(_ usage: rusage) -> Double {
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
                Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let report: [String: Any] = [
            "solid": ProcessInfo.processInfo.environment["MEETING_CHROME_SOLID"] == "1",
            "seconds": elapsed, "cpu_percent_one_core": (cpu(after) - cpu(before)) / elapsed * 100,
            "peak_rss_bytes": after.ru_maxrss, "worst_100ms_tick_ms": worstTick * 1_000,
            "pid": getpid(), "scope": "10fps synthetic guest stage, no capture, network or battery measurement"
        ]
        print("MEETING_CHROME_VISIBLE_PROFILE " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Visible glass profile fixture"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
