#if DEBUG
import ConferenceCore
import Darwin
import UIKit
import XCTest
@testable import RockNRoll

/// Opt-in, repeatable app-owned UIKit workloads. CPU is a work proxy, not battery power.
@MainActor
final class PerformanceEvaluationTests: XCTestCase {
    func testProfiledStripComparison() async throws {
        guard ProcessInfo.processInfo.environment["ROCK_PERFORMANCE_PROFILE"] == "1" else {
            throw XCTSkip("Opt-in bounded profiling comparison")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), host = UIViewController()
        host.view.backgroundColor = .black
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let baseline = PerformanceStripBaseline(frame: CGRect(x: 0, y: 60, width: 360, height: 46))
        let candidate = MeetingParticipantStrip(frame: baseline.frame)
        print("PERFORMANCE_PROFILE_READY pid=\(getpid())")
        try await Task.sleep(for: .seconds(20)) // Attach Power/Time Profiler during this explicit warm-up.
        for (name, strip, update) in [("baseline", baseline as UIScrollView, baseline.update),
                                     ("candidate", candidate as UIScrollView, candidate.update)] {
            host.view.addSubview(strip)
            var items = (0..<100).map { MeetingStripItem(id: String($0), name: "Participant \($0)", isShare: false,
                audio: .init(microphoneOn: true, speaking: false)) }
            update(items, "0"); strip.layoutIfNeeded()
            let beforeCPU = cpu(), beforeWall = ProcessInfo.processInfo.systemUptime
            var updates = 0
            for batch in 0..<200 {
                for step in 0..<10 {
                    let index = (batch * 10 + step) % 100
                    items[index] = .init(id: String(index), name: "Participant \(index)", isShare: false,
                        audio: .init(microphoneOn: true, speaking: batch / 10 % 2 == 0))
                    update(items, "0"); strip.layoutIfNeeded(); updates += 1
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            print("PERFORMANCE_PROFILE phase=\(name) updates=\(updates) start=\(beforeWall) duration_s=\(ProcessInfo.processInfo.systemUptime-beforeWall) cpu_ms=\((cpu()-beforeCPU)*1000)")
            strip.removeFromSuperview()
        }
    }
    func testParticipantStripWork() throws {
        guard ProcessInfo.processInfo.environment["ROCK_PERFORMANCE_EVALUATION"] == "1" else {
            throw XCTSkip("Opt-in performance workload")
        }
        let strip = MeetingParticipantStrip(frame: CGRect(x: 0, y: 0, width: 1024, height: 46))
        var items = (0..<100).map { MeetingStripItem(id: String($0), name: "Participant \($0)", isShare: false,
            audio: .init(microphoneOn: true, speaking: false)) }
        strip.update(items, selected: "0"); strip.layoutIfNeeded()
        let beforeCPU = cpu(), beforeWall = ProcessInfo.processInfo.systemUptime
        for index in 0..<300 {
            let target = index % items.count
            items[target] = .init(id: String(target), name: "Participant \(target)", isShare: false,
                audio: .init(microphoneOn: true, speaking: index / items.count % 2 == 0))
            strip.update(items, selected: "0"); strip.layoutIfNeeded()
        }
        print("PERFORMANCE_STRIP participants=100 updates=300 cpu_ms=\((cpu()-beforeCPU)*1000) wall_ms=\((ProcessInfo.processInfo.systemUptime-beforeWall)*1000)")
        XCTAssertEqual(strip.subviews.compactMap { $0 as? UIButton }.count, 100)
    }
    func testConversationBurstWork() async throws {
        guard ProcessInfo.processInfo.environment["ROCK_PERFORMANCE_EVALUATION"] == "1" else {
            throw XCTSkip("Opt-in performance workload")
        }
        for _ in 0..<50 where UIApplication.shared.applicationState != .active {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard UIApplication.shared.applicationState == .active else { throw XCTSkip("Visible workload requires an active test host") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        defer { window.isHidden = true; previous?.makeKey() }
        let chat = ChatStore(); chat.reactionHistoryAvailable = true; chat.reactionHistory.beginMeeting()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<200 {
            chat.reactionHistory.receive(kind: .like, participantID: "participant", displayName: "Participant",
                receivedAt: start.addingTimeInterval(Double(index) * 20))
        }
        let panel = ConversationPanelViewController(catchUp: CatchUpStore(), chat: chat)
        let initialCPU = cpu(), initialWall = ProcessInfo.processInfo.systemUptime
        window.rootViewController = panel; window.makeKeyAndVisible()
        panel.view.layoutIfNeeded(); await drain()
        XCTAssertEqual(rows(panel.view), 200, "Reject timings without visible initial history")
        print("PERFORMANCE_PANEL phase=open cpu_ms=\((cpu()-initialCPU)*1000) wall_ms=\((ProcessInfo.processInfo.systemUptime-initialWall)*1000)")
        for visible in [true, false] {
            if !visible { panel.viewDidDisappear(false) }
            let beforeCPU = cpu(), beforeWall = ProcessInfo.processInfo.systemUptime
            for index in 0..<30 {
                chat.reactionHistory.receive(kind: .wave, participantID: "participant", displayName: "Participant",
                    receivedAt: start.addingTimeInterval(Double(200 + (visible ? 0 : 30) + index) * 20))
            }
            await drain()
            if visible {
                XCTAssertEqual(UIApplication.shared.applicationState, .active)
                XCTAssertEqual(rows(panel.view), 230, "Reject timings if visible work was deferred")
            }
            print("PERFORMANCE_PANEL phase=\(visible ? "visible" : "hidden") events=30 cpu_ms=\((cpu()-beforeCPU)*1000) wall_ms=\((ProcessInfo.processInfo.systemUptime-beforeWall)*1000) rows=\(rows(panel.view))")
        }
        XCTAssertEqual(chat.reactionHistory.events.count, 260)
        panel.viewDidAppear(false); await drain()
        XCTAssertEqual(rows(panel.view), 260, "Coalescing must retain every distinct event")
    }

    private func drain() async {
        for _ in 0..<8 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }
    private func rows(_ root: UIView) -> Int {
        (root is ReactionHistoryRowView ? 1 : 0) + root.subviews.reduce(0) { $0 + rows($1) }
    }
    private func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
#endif
