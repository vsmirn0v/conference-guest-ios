import AppKit
import SwiftUI

/// AppKit-backed segmented control using proportional segment sizing and a
/// selection-independent `sizeThatFits` so switching tabs never changes bar width.
struct NativeSegmentedControl<Selection: Hashable>: NSViewRepresentable {
    struct Option: Equatable {
        let value: Selection
        let title: String
    }

    let label: String
    @Binding var selection: Selection
    let options: [Option]
    var distribution: NSSegmentedControl.Distribution = .fillProportionally
    var expandsToFill: Bool = false
    var accessibilityID: String? = nil

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = distribution
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(expandsToFill ? .defaultLow : .required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .vertical)
        apply(to: control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        apply(to: control)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        let width: CGFloat
        if expandsToFill, let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else if let proposed = proposal.width, proposed.isFinite {
            width = min(intrinsic.width, proposed)
        } else {
            width = intrinsic.width
        }
        return CGSize(width: width, height: intrinsic.height)
    }

    private func apply(to control: NSSegmentedControl) {
        control.isEnabled = isEnabled
        control.setAccessibilityLabel(label)
        if let accessibilityID { control.setAccessibilityIdentifier(accessibilityID) }

        let nsSize: NSControl.ControlSize = switch controlSize {
        case .mini: .mini
        case .small: .small
        case .regular: .regular
        case .large: .large
        case .extraLarge: .large
        @unknown default: .regular
        }

        var layoutChanged = false
        if control.controlSize != nsSize {
            control.controlSize = nsSize
            layoutChanged = true
        }
        if control.segmentDistribution != distribution {
            control.segmentDistribution = distribution
            layoutChanged = true
        }
        let titles = options.map(\.title)
        let currentTitles = (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
        if currentTitles != titles {
            control.segmentCount = titles.count
            for (index, title) in titles.enumerated() {
                control.setLabel(title, forSegment: index)
            }
            layoutChanged = true
        }
        if layoutChanged {
            control.invalidateIntrinsicContentSize()
        }

        let targetIndex = options.firstIndex { $0.value == selection } ?? -1
        if control.selectedSegment != targetIndex {
            control.selectedSegment = targetIndex
        }
    }

    final class Coordinator: NSObject {
        var parent: NativeSegmentedControl

        init(parent: NativeSegmentedControl) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard parent.options.indices.contains(index) else { return }
            let chosen = parent.options[index].value
            if chosen != parent.selection {
                parent.selection = chosen
            }
        }
    }
}
