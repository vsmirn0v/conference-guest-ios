import CoreMedia
import Foundation

/// VP9 uncompressed key-frame header and ISO-BMFF vpcC configuration.
/// References: WebM VP9 bitstream specification and VP Codec ISO media binding.
struct VP9VideoFormat: Equatable {
    let profile: Int
    let bitDepth: Int
    let colorSpace: Int
    let fullRange: Bool
    let width: Int
    let height: Int

    var hardwareCompatible: Bool {
        profile == 0 && bitDepth == 8 && (0..<6).contains(colorSpace) &&
            (1...8192).contains(width) && (1...8192).contains(height) && width * height <= 16_777_216
    }

    static func keyFrame(_ data: Data) -> Self? {
        var bits = Bits(data: data)
        guard bits.read(2) == 2, let low = bits.read(1), let high = bits.read(1) else { return nil }
        let profile = low | (high << 1)
        if profile == 3, bits.read(1) != 0 { return nil }
        guard bits.read(1) == 0, bits.read(1) == 0,
              bits.read(1) != nil, bits.read(1) != nil, bits.read(24) == 0x498342 else { return nil }
        let depth: Int
        if profile >= 2 {
            guard let highDepth = bits.read(1) else { return nil }; depth = highDepth == 0 ? 10 : 12
        } else { depth = 8 }
        guard let color = bits.read(3) else { return nil }
        let fullRange: Bool
        if color == 7 {
            guard profile == 1 || profile == 3, bits.read(1) == 0 else { return nil }
            fullRange = true
        } else {
            guard let range = bits.read(1) else { return nil }; fullRange = range == 1
            if profile == 1 || profile == 3 {
                guard bits.read(1) != nil, bits.read(1) != nil, bits.read(1) == 0 else { return nil }
            }
        }
        guard let w = bits.read(16), let h = bits.read(16) else { return nil }
        return Self(profile: profile, bitDepth: depth, colorSpace: color, fullRange: fullRange, width: w + 1, height: h + 1)
    }

    func description() -> CMVideoFormatDescription? {
        guard hardwareCompatible else { return nil }
        // ISO/IEC color identifiers, mapped from the VP9 color-space enum.
        let color: [UInt8]
        switch colorSpace {
        case 1, 3: color = [6, 6, 6] // SMPTE 170M / BT.601
        case 2: color = [1, 1, 1] // BT.709
        case 4: color = [7, 7, 7] // SMPTE 240M
        case 5: color = [9, 14, 9] // BT.2020
        default: color = [2, 2, 2] // Unspecified
        }
        let configuration = Data([1, 0, 0, 0, UInt8(profile), 0,
            UInt8((bitDepth << 4) | (fullRange ? 1 : 0))] + color + [0, 0])
        var result: CMVideoFormatDescription?
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: ["vpcC": configuration]] as CFDictionary
        guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_VP9,
            width: Int32(width), height: Int32(height), extensions: extensions, formatDescriptionOut: &result) == noErr else { return nil }
        return result
    }

    private struct Bits {
        let data: Data
        var offset = 0
        mutating func read(_ count: Int) -> Int? {
            guard offset + count <= data.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                value = (value << 1) | Int((data[data.startIndex + offset / 8] >> (7 - offset % 8)) & 1)
                offset += 1
            }
            return value
        }
    }
}
