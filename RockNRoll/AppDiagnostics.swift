import AVFoundation
import Foundation
import Network
import SwiftUI
import UIKit
import os

/// Diagnostic events kept on this device for 7 days, so a person can send them after a
/// problem. Allowlisted states, counters and reason codes only: no meeting links, room
/// names, participant names, chat or audio. Nothing is uploaded; the person shares a zip.
enum AppDiagnostics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var history: [String] = []
    private static let historyCapacity = 400
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RockNRoll", category: "diagnostics")
    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []
    private static let pathMonitor = NWPathMonitor()
    nonisolated(unsafe) private static var networkSummary: [String: Any] = [:]
    nonisolated(unsafe) private static var started = false

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    @MainActor static func start() {
        guard !started else { return }
        started = true
        NativeDiagnosticsLog.shared.start()
        NativeDiagnosticReports.shared.onSaved = { log("diagnostic-reports-saved", ["count": $0]) }
        NativeDiagnosticReports.shared.start()
        log("app-launch", ["version": appVersion, "system": UIDevice.current.systemVersion, "device": deviceModel,
                           "mac": ProcessInfo.processInfo.isiOSAppOnMac])
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
            var fields: [String: Any] = ["type": note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 99]
            if let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt { fields["options"] = options }
            if let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt { fields["reason"] = reason }
            log("audio-interruption", fields)
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { note in
            var fields = audioRoute()
            fields["reason"] = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 99
            log("audio-route-change", fields)
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: nil) { _ in
            log("audio-media-services-lost")
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
            log("audio-media-services-reset")
        })
        for (name, event) in [(UIApplication.didEnterBackgroundNotification, "app-background"),
                              (UIApplication.willEnterForegroundNotification, "app-foreground"),
                              (UIApplication.didReceiveMemoryWarningNotification, "memory-warning")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in log(event) })
        }
        pathMonitor.pathUpdateHandler = { path in
            let summary = network(path)
            lock.lock()
            let changed = !NSDictionary(dictionary: networkSummary).isEqual(to: summary)
            networkSummary = summary
            lock.unlock()
            if changed { log("network", summary) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "rocknroll.diagnostics.network", qos: .utility))
    }

    /// Callers pass allowlisted fields only. Never pass URLs, names, SDP, ICE or credentials.
    static func log(_ event: String, _ fields: [String: Any] = [:]) {
        var value = fields
        value["event"] = event
        value["uptime"] = Int(ProcessInfo.processInfo.systemUptime * 1000) / 1000
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        logger.log("\(line, privacy: .public)")
        lock.lock()
        history.append(line)
        if history.count > historyCapacity { history.removeFirst(history.count - historyCapacity) }
        lock.unlock()
        NativeDiagnosticsLog.shared.append(line)
    }

    static func audioRoute() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        return ["outputs": session.currentRoute.outputs.map(\.portType.rawValue),
                "inputs": session.currentRoute.inputs.map(\.portType.rawValue),
                "category": session.category.rawValue, "mode": session.mode.rawValue,
                "sampleRate": Int(session.sampleRate), "otherAudio": session.isOtherAudioPlaying]
    }

    static func network(_ path: NWPath) -> [String: Any] {
        func name(_ type: NWInterface.InterfaceType) -> String {
            switch type {
            case .wifi: "wifi"
            case .cellular: "cellular"
            case .wiredEthernet: "wired"
            case .loopback: "loopback"
            default: "other"
            }
        }
        let status: String = switch path.status {
        case .satisfied: "satisfied"
        case .unsatisfied: "unsatisfied"
        case .requiresConnection: "requiresConnection"
        @unknown default: "unknown"
        }
        let used = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .other].filter(path.usesInterfaceType).map(name)
        return ["status": status, "uses": used, "available": path.availableInterfaces.map { name($0.type) },
                "expensive": path.isExpensive, "constrained": path.isConstrained,
                "ipv4": path.supportsIPv4, "ipv6": path.supportsIPv6]
    }

    /// Text at the top of the exported archive.
    @MainActor static func report(now: Date = Date()) -> String {
        func json(_ value: Any) -> String {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "unavailable" }
            return String(decoding: data, as: UTF8.self)
        }
        func access(_ type: AVMediaType) -> String {
            switch AVCaptureDevice.authorizationStatus(for: type) {
            case .authorized: "allowed"
            case .denied: "denied"
            case .restricted: "restricted"
            case .notDetermined: "not asked"
            @unknown default: "unknown"
            }
        }
        let info = ProcessInfo.processInfo
        lock.lock()
        let events = history, network = networkSummary
        lock.unlock()
        var lines = ["Rock'N'Roll diagnostics",
            "Created: \(ISO8601DateFormatter().string(from: now)) (uptime \(Int(info.systemUptime)))",
            "App: \(appVersion)",
            "System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) on \(deviceModel)\(info.isiOSAppOnMac ? " (Mac)" : "")",
            "Language: \(Locale.preferredLanguages.first ?? "?")",
            "Microphone: \(access(.audio)); camera: \(access(.video))",
            "Audio route: \(json(audioRoute()))",
            "Network: \(json(network))",
            "Low Power Mode: \(info.isLowPowerModeEnabled ? "on" : "off"); thermal state: \(info.thermalState.rawValue)",
            "Saved logs: \(NativeDiagnosticsLog.shared.files.count) files; crash and hang reports: \(NativeDiagnosticReports.shared.files.count)",
            "Recent events this launch (\(events.count), oldest first):"]
        lines += events
        return lines.joined(separator: "\n")
    }

    /// Builds the zip in a fresh temporary folder and returns its location.
    @MainActor static func makeArchive(now: Date = Date()) throws -> URL {
        log("diagnostics-export")
        NativeDiagnosticsLog.shared.flush()
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticsExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("RockNRoll Diagnostics \(stamp.string(from: now)).zip")
        try NativeDiagnosticsArchive.make(report: report(now: now), logs: NativeDiagnosticsLog.shared.files,
                                          reports: NativeDiagnosticReports.shared.files, destination: destination)
        return destination
    }
}

/// Settings → Diagnostics: send saved logs after a problem.
struct DiagnosticsSettingsView: View {
    private struct Export: Identifiable { let id = UUID(); let url: URL }
    @State private var export: Export?
    @State private var failure: String?
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text(L("If a meeting loses sound or disconnects, send diagnostics to support soon after. They help find the cause."))
                    .font(.subheadline)
            }
            Section {
                Button {
                    do { export = Export(url: try AppDiagnostics.makeArchive()) }
                    catch { failure = error.localizedDescription }
                } label: { Label(L("Export diagnostics"), systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("diagnostics.export")
                Button {
                    UIPasteboard.general.string = AppDiagnostics.report()
                    copied = true
                } label: { Label(copied ? L("Diagnostics copied") : L("Copy diagnostics"), systemImage: "doc.on.doc") }
                    .accessibilityIdentifier("diagnostics.copy")
            } footer: {
                Text(L("Diagnostics include the app and system versions, audio route, network type and connection events from the last 7 days. They include no meeting links, names, chat or audio. Nothing is sent until you share it."))
            }
        }
        .navigationTitle(L("Diagnostics"))
        .sheet(item: $export) { item in
            DiagnosticsShareSheet(items: [item.url]).ignoresSafeArea()
        }
        .alert(L("Unable to export diagnostics"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(L("OK"), role: .cancel) {}
        } message: { Text(failure ?? "") }
    }
}

private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
