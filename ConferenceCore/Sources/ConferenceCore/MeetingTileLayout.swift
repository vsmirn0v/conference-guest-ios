import CoreGraphics
import Foundation

public enum MeetingLayoutMode: String, CaseIterable, Sendable {
    case grid, speaker
}

/// Tile geometry never changes the source video's aspect ratio. Content is fit
/// inside these bounds by its renderer; large rosters scroll as complete rows.
public enum MeetingTileLayout {
    public static func frames(count: Int, size: CGSize, mode: MeetingLayoutMode) -> [CGRect] {
        guard count > 0, size.width > 0, size.height > 0 else { return [] }
        if count == 1 { return [CGRect(origin: .zero, size: size)] }
        let gap: CGFloat = 8
        if mode == .speaker {
            let strip = min(160, max(100, size.height * 0.25))
            let stage = max(80, size.height - strip - gap)
            let columns = max(1, min(count - 1, Int(size.width / 160)))
            let width = max(0, (size.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
            return [CGRect(x: 0, y: 0, width: size.width, height: stage)] + (0..<(count - 1)).map {
                CGRect(x: CGFloat($0 % columns) * (width + gap),
                       y: stage + gap + CGFloat($0 / columns) * (strip + gap), width: width, height: strip)
            }
        }
        let columns: Int
        if count == 2 { columns = size.width > size.height ? 2 : 1 }
        else { columns = min(count, size.width < 320 ? 1 : max(2, min(4, Int(size.width / 240)))) }
        let rows = (count + columns - 1) / columns
        let visibleRows = min(rows, max(1, Int(size.height / 140)))
        let width = max(0, (size.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        let height = max(0, (size.height - CGFloat(visibleRows - 1) * gap) / CGFloat(visibleRows))
        return (0..<count).map { index in
            let rowCount = min(columns, count - (index / columns) * columns)
            let inset = (size.width - CGFloat(rowCount) * width - CGFloat(rowCount - 1) * gap) / 2
            return CGRect(x: inset + CGFloat(index % columns) * (width + gap),
                          y: CGFloat(index / columns) * (height + gap), width: width, height: height)
        }
    }
}
