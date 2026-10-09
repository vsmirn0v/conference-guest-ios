import Foundation

/// H.264 section E.1.1. Only the colour-description fields are replaced.
/// The encoder's range, timing, cropping, HRD and every other NAL stay intact.
struct H264ColorDescription: Equatable {
    let primaries: UInt8
    let transfer: UInt8
    let matrix: UInt8
}

enum H264ColorSignalling {
    static func applying(_ color: H264ColorDescription, to annexB: Data) -> Data {
        let bytes = Array(annexB)
        var starts: [(prefix: Int, payload: Int)] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, index + 3)); index += 3; continue
                }
                if bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, index + 4)); index += 4; continue
                }
            }
            index += 1
        }
        guard starts.contains(where: { $0.payload < bytes.count && bytes[$0.payload] & 0x1f == 7 }) else { return annexB }
        var result = Data(bytes.prefix(starts[0].prefix))
        for (offset, start) in starts.enumerated() {
            let end = offset + 1 < starts.count ? starts[offset + 1].prefix : bytes.count
            result.append(contentsOf: bytes[start.prefix..<start.payload])
            let nal = Array(bytes[start.payload..<end])
            result.append(contentsOf: rewrite(nal, color: color) ?? nal)
        }
        return result
    }

    private static func rewrite(_ nal: [UInt8], color: H264ColorDescription) -> [UInt8]? {
        guard let header = nal.first, header & 0x1f == 7, nal.count <= 4096 else { return nil }
        var rbsp: [UInt8] = [], zeros = 0
        for (index, byte) in nal.enumerated().dropFirst() {
            if zeros == 2, byte == 3 {
                guard index + 1 < nal.count, nal[index + 1] <= 3 else { return nil }
                zeros = 0; continue
            }
            rbsp.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        var bits = rbsp.flatMap { byte in (0..<8).reversed().map { (byte >> $0) & 1 } }
        guard let stop = bits.lastIndex(of: 1) else { return nil }
        bits = Array(bits[...stop]) // Keep rbsp_stop_one_bit, repad after editing.
        var reader = Reader(bits: bits)
        guard let profile = reader.read(8), reader.read(16) != nil, reader.ue() != nil else { return nil }
        guard [66, 77, 88, 100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) else { return nil }
        // Profiles with chroma_format_idc and scaling matrices (H.264 7.3.2.1.1).
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            guard let chroma = reader.ue(), chroma <= 3 else { return nil }
            if chroma == 3, reader.read(1) == nil { return nil }
            guard reader.ue() != nil, reader.ue() != nil, reader.read(1) != nil,
                  let scaling = reader.read(1) else { return nil }
            if scaling == 1 {
                for index in 0..<(chroma == 3 ? 12 : 8) {
                    guard let present = reader.read(1) else { return nil }
                    if present == 1, !reader.skipScalingList(count: index < 6 ? 16 : 64) { return nil }
                }
            }
        }
        guard reader.ue() != nil, let order = reader.ue(), order <= 2 else { return nil }
        if order == 0, reader.ue() == nil { return nil }
        if order == 1 {
            guard reader.read(1) != nil, reader.se() != nil, reader.se() != nil,
                  let cycle = reader.ue(), cycle <= 256 else { return nil }
            for _ in 0..<cycle { if reader.se() == nil { return nil } }
        }
        guard reader.ue() != nil, reader.read(1) != nil, reader.ue() != nil, reader.ue() != nil,
              let frameOnly = reader.read(1) else { return nil }
        if frameOnly == 0, reader.read(1) == nil { return nil }
        guard reader.read(1) != nil, let crop = reader.read(1) else { return nil }
        if crop == 1 { for _ in 0..<4 { if reader.ue() == nil { return nil } } }
        let vuiIndex = reader.index
        guard let vui = reader.read(1) else { return nil }
        var format = 5, fullRange = 0
        var wanted = [Int(color.primaries), Int(color.transfer), Int(color.matrix)]
        let replaced: Range<Int>
        var prefix: [UInt8] = []
        var suffix: [UInt8] = []
        if vui == 0 {
            // No video_signal_type means video_format=5 and limited range.
            replaced = vuiIndex..<reader.index
            prefix = [1, 0, 0] // VUI present, aspect_ratio absent, overscan absent.
            suffix = [0, 0, 0, 0, 0, 0] // chroma location, timing, both HRDs, pic_struct, restriction.
        } else {
            guard let aspect = reader.read(1) else { return nil }
            if aspect == 1 {
                guard let idc = reader.read(8) else { return nil }
                if idc == 255, reader.read(32) == nil { return nil }
            }
            guard let overscan = reader.read(1) else { return nil }
            if overscan == 1, reader.read(1) == nil { return nil }
            let start = reader.index
            guard let signal = reader.read(1) else { return nil }
            if signal == 1 {
                guard let existingFormat = reader.read(3), let existingRange = reader.read(1),
                      let description = reader.read(1) else { return nil }
                format = existingFormat; fullRange = existingRange
                if description == 1 {
                    guard let primaries = reader.read(8), let transfer = reader.read(8),
                          let matrix = reader.read(8) else { return nil }
                    // Fill unspecified fields only when existing explicit fields agree.
                    let fields = Array(zip([primaries, transfer, matrix], wanted))
                    guard fields.contains(where: { $0.0 == 2 && $0.1 != 2 }),
                          fields.allSatisfy({ $0.0 == 2 || $0.1 == 2 || $0.0 == $0.1 }) else { return nil }
                    wanted = fields.map { $0.0 == 2 ? $0.1 : $0.0 }
                }
            }
            replaced = start..<reader.index
        }
        let signal = [UInt8(1)] + binary(format, count: 3) + [UInt8(fullRange), 1]
            + binary(wanted[0], count: 8) + binary(wanted[1], count: 8)
            + binary(wanted[2], count: 8)
        bits.replaceSubrange(replaced, with: prefix + signal + suffix)
        while bits.count % 8 != 0 { bits.append(0) }
        var output = [header]; zeros = 0
        for offset in stride(from: 0, to: bits.count, by: 8) {
            let byte = bits[offset..<offset + 8].reduce(UInt8(0)) { $0 << 1 | $1 }
            if zeros == 2, byte <= 3 { output.append(3); zeros = 0 }
            output.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }

    private static func binary(_ value: Int, count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8((value >> $0) & 1) }
    }
    private struct Reader {
        let bits: [UInt8]
        var index = 0
        mutating func read(_ count: Int) -> Int? {
            guard count <= 32, index + count < bits.count else { return nil }
            defer { index += count }
            return bits[index..<index + count].reduce(0) { $0 << 1 | Int($1) }
        }
        mutating func ue() -> Int? {
            var zeros = 0
            while true {
                guard let bit = read(1) else { return nil }
                if bit == 1 { break }
                zeros += 1; if zeros > 30 { return nil }
            }
            guard let suffix = read(zeros) else { return nil }
            return (1 << zeros) - 1 + suffix
        }
        mutating func se() -> Int? {
            guard let value = ue() else { return nil }
            return value % 2 == 0 ? -value / 2 : (value + 1) / 2
        }
        mutating func skipScalingList(count: Int) -> Bool {
            var last = 8, next = 8
            for _ in 0..<count {
                if next != 0 {
                    guard let delta = se() else { return false }
                    next = ((last + delta) % 256 + 256) % 256
                }
                if next != 0 { last = next }
            }
            return true
        }
    }
}
