import SwiftUI

/// Small, stable backgrounds for controls around the video. Accessibility uses
/// the same opaque surface policy as the shipping MeetingChromeSurface.
private struct NativeDesktopMeetingChrome: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    private static let solid = Color(red: 0.12, green: 0.14, blue: 0.21)
    #if DEBUG
    private static let forceSolidForProfiling = ProcessInfo.processInfo.environment["MEETING_CHROME_SOLID"] == "1"
    #endif

    private var requiresSolid: Bool {
        #if DEBUG
        if Self.forceSolidForProfiling { return true }
        #endif
        return reduceTransparency || reduceMotion || contrast == .increased
    }
    var body: some View {
        Group {
            if requiresSolid {
                Capsule().fill(Self.solid)
            } else if #available(macOS 26.0, *) {
                Capsule().fill(.clear).glassEffect(.regular.interactive(false), in: Capsule())
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
        // Only the material adopts the dark video context; native menus and
        // the controls retain their surrounding appearance and identity.
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    func nativeMeetingChrome() -> some View { background { NativeDesktopMeetingChrome() } }
}
