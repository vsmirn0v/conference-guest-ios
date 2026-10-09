import SwiftUI

/// Standalone, signed development harness. Synthetic localhost media only;
/// it does not install over the user's app or capture a camera/microphone.
@main struct DeviceMain: App {
    var body: some Scene { WindowGroup { DeviceProbeView() } }
}
private struct DeviceProbeView: View {
    @State private var status = "VP9 hybrid check running…"
    @State private var started = false
    var body: some View {
        Text(status).multilineTextAlignment(.center).padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white).background(.black)
            .task { @MainActor in
                guard !started else { return }; started = true
                probeLog("device-harness-started")
                do {
                    try await HybridLoopback.run()
                    if let fixture = Bundle.main.url(forResource: "av1-fixture", withExtension: "json") { try HardwareProbe.run(fixture) }
                    status = "PASS\nHardware VP9, software SVC, and per-stream fallback"
                    probeLog("DEVICE_HYBRID_PASS")
                } catch {
                    status = "FAILED\n\(error)"; probeLog("DEVICE_HYBRID_FAIL", ["error": String(describing: error)])
                }
            }
    }
}
