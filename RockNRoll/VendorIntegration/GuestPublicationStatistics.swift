import Foundation

/// The pinned native stats collector reports encoding activity without public
/// sender GetParameters, which would invalidate the SDK's outstanding writes.
enum GuestPublicationStatistics {
    static func activeVideo(_ records: [CameraUplinkStatistics.Record], mid: String) -> [CameraUplinkStatistics.Record]? {
        let active = records.filter {
            $0.type == "outbound-rtp" && $0.values["mid"] as? String == mid &&
                $0.values["kind"] as? String == "video" &&
                ($0.values["active"] as? NSNumber)?.boolValue == true
        }
        // No activity evidence means paused/unknown, never an encoder failure.
        return active.isEmpty ? nil : active
    }

    static func encodedFrames(_ active: [CameraUplinkStatistics.Record]) -> Int64? {
        guard !active.isEmpty else { return nil }
        var total: Int64 = 0
        for record in active {
            guard let counter = record.values["framesEncoded"] as? NSNumber, counter.int64Value >= 0 else { return nil }
            let sum = total.addingReportingOverflow(counter.int64Value)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
}
