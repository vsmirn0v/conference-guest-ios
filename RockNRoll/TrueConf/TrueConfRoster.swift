import CoreGraphics
import Foundation

struct TrueConfRoster {
    struct Participant {
        let id: String
        var name: String
        var devices: Int
        var videoType: Int
        var microphoneOn: Bool { devices & 255 == 0 }
        var cameraOn: Bool { (devices >> 16) & 255 == 0 && videoType != 2 }
        var screenShareOn: Bool { (devices >> 16) & 255 == 0 && videoType == 2 }
    }
    private(set) var participants: [String: Participant] = [:]
    mutating func apply(_ body: [String: Any]) throws {
        guard let type = body["type"] as? Int, (1...4).contains(type), let list = body["list"] as? [[String: Any]], list.count <= 1000 else { throw TrueConfError.invalidResponse }
        if type == 1 || type == 4 { participants.removeAll() }
        for value in list {
            guard let id = value["trueconfId"] as? String, !id.isEmpty, id.utf8.count <= 512 else { throw TrueConfError.invalidResponse }
            if type == 3 { participants.removeValue(forKey: id); continue }
            let existing = participants[id]
            participants[id] = .init(id: id, name: String((value["displayname"] as? String ?? existing?.name ?? L("Musician")).prefix(256)),
                devices: value["DeviceStatus"] as? Int ?? existing?.devices ?? 262148,
                videoType: value["videoType"] as? Int ?? existing?.videoType ?? 0)
        }
        guard participants.count <= 1000 else { throw TrueConfError.invalidResponse }
    }
    mutating func updateDevices(_ body: [String: Any]) {
        guard let id = body["UserName"] as? String, let status = body["DeviceStatus"] as? Int else { return }
        participants[id]?.devices = status
    }
    static func regions(_ body: [String: Any]) throws -> [String: CGRect] {
        if let list = body["list"] as? [Any], list.isEmpty { return [:] }
        guard let width = (body["width"] as? NSNumber)?.doubleValue, let height = (body["height"] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width >= 2, height >= 2, width <= 4096, height <= 4096,
              let list = body["list"] as? [[String: Any]], list.count <= 1000 else { throw TrueConfError.invalidResponse }
        var result: [String: CGRect] = [:]
        for slot in list {
            guard let id = slot["id"] as? String, let numbers = slot["rect"] as? [NSNumber], numbers.count == 4 else { throw TrueConfError.invalidResponse }
            let rect = numbers.map(\.doubleValue)
            guard
                  rect.allSatisfy(\.isFinite), rect[0] >= 0, rect[1] >= 0, rect[2] - rect[0] >= 2, rect[3] - rect[1] >= 2,
                  rect[2] <= width + 1, rect[3] <= height + 1 else { throw TrueConfError.invalidResponse }
            result[id] = CGRect(x: rect[0] / width, y: rect[1] / height, width: (min(rect[2], width) - rect[0]) / width,
                                height: (min(rect[3], height) - rect[1]) / height)
        }
        return result
    }
}
