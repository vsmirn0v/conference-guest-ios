import SwiftUI
import UIKit

/// Background-only chrome for transient controls. Reading and media surfaces
/// keep their own opaque backgrounds; this view never owns a preview or action.
struct ControlChromeBackground: UIViewRepresentable {
    var cornerRadius: CGFloat = 0
    func makeUIView(context: Context) -> MeetingChromeSurface {
        MeetingChromeSurface(cornerRadius: cornerRadius, fallbackColor: .secondarySystemGroupedBackground)
    }
    func updateUIView(_ view: MeetingChromeSurface, context: Context) {}
}
