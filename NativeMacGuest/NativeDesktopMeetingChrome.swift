import SwiftUI

/// Put controls inside the regular-glass effect hierarchy so its content can
/// adapt to the sampled backdrop. Accessibility uses an opaque semantic fill.
private struct NativeDesktopMeetingChrome: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    #if DEBUG
    private static let forceSolidForProfiling = ProcessInfo.processInfo.environment["MEETING_CHROME_SOLID"] == "1"
    #endif

    private var requiresSolid: Bool {
        #if DEBUG
        if Self.forceSolidForProfiling { return true }
        #endif
        return reduceTransparency || reduceMotion || contrast == .increased
    }
    func body(content: Content) -> some View {
        Group {
            if requiresSolid {
                content.background {
                    Capsule().fill(Color(nsColor: .controlBackgroundColor)).allowsHitTesting(false).accessibilityHidden(true)
                }
            } else if #available(macOS 26.0, *) {
                content.glassEffect(.regular.interactive(false), in: Capsule())
            } else {
                content.background(.ultraThinMaterial, in: Capsule())
            }
        }.foregroundStyle(.primary)
    }
}

extension View {
    func nativeMeetingChrome() -> some View { modifier(NativeDesktopMeetingChrome()) }
}
