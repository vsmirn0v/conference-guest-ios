import CoreImage
import Foundation

/// Formal synthetic-fixture verification; no OCR, model, service or language routing.
enum SharingPixelAcceptance {
    enum Failure: Error { case image, dimensions, marker }
    static let method = "nonce-phase-and-raster-v1"
    static let maximumBalancedMAE = 16.0
    static let minimumContrastRatio = 0.80

    struct Raster {
        let width: Int
        let height: Int
        var luma: [UInt8]
        var rgba: [UInt8]

        init(width: Int, height: Int, luma: [UInt8]) {
            precondition(width > 0 && height > 0 && luma.count == width * height)
            self.width = width; self.height = height; self.luma = luma
            self.rgba = [UInt8](repeating: 255, count: luma.count * 4)
            for index in luma.indices { for channel in 0..<3 { self.rgba[index * 4 + channel] = luma[index] } }
        }

        init(url: URL) throws {
            guard let image = CIImage(contentsOf: url) else { throw Failure.image }
            let width = Int(image.extent.width), height = Int(image.extent.height)
            guard width > 0, height > 0, width <= 4096, height <= 4096 else { throw Failure.dimensions }
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            CIContext().render(image, toBitmap: &rgba, rowBytes: width * 4,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var luma = [UInt8](repeating: 0, count: width * height)
            var topRGBA = rgba
            for y in 0..<height {
                for x in 0..<width {
                    let input = (y * width + x) * 4
                    luma[y * width + x] = UInt8((77 * Int(rgba[input]) + 150 * Int(rgba[input + 1]) + 29 * Int(rgba[input + 2])) >> 8)
                    for channel in 0..<4 { topRGBA[(y * width + x) * 4 + channel] = rgba[input + channel] }
                }
            }
            self.width = width; self.height = height; self.luma = luma; self.rgba = topRGBA
        }

        subscript(_ x: Int, _ y: Int) -> UInt8 { luma[y * width + x] }
        func green(_ x: Double, _ y: Double) -> Bool {
            let index = (Int(y * Double(height)) * width + Int(x * Double(width))) * 4
            return rgba[index + 1] > 130 && Int(rgba[index + 1]) > Int(rgba[index]) + 70 && Int(rgba[index + 1]) > Int(rgba[index + 2]) + 70
        }
    }

    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var result: UInt8 = 0
        for byte in bytes {
            result ^= byte
            for _ in 0..<8 { result = result & 0x80 == 0 ? result &<< 1 : (result &<< 1) ^ 0x07 }
        }
        return result
    }

    static func payload(nonce: [UInt8], phase: UInt8) -> [UInt8] {
        precondition(nonce.count == 8 && phase <= 6)
        let bytes: [UInt8] = [0xC7, 1] + nonce + [phase]
        return bytes + [crc8(bytes)]
    }

    /// Top-left coordinates in both the flipped fixture view and decoded raster.
    static func markerOrigin(width: Int) -> (x: Int, y: Int) { (width - 304, 32) }

    static func markerCells(payload: [UInt8], width: Int) -> [(rect: CGRect, black: Bool)] {
        precondition(payload.count == 12)
        let origin = markerOrigin(width: width)
        return (0..<96).flatMap { bit -> [(CGRect, Bool)] in
            let black = payload[bit / 8] & (0x80 >> (bit % 8)) != 0
            let x = origin.x + 8 + (bit % 16) * 16, y = origin.y + 8 + (bit / 16) * 8
            return [(CGRect(x: x, y: y, width: 8, height: 8), black),
                    (CGRect(x: x + 8, y: y, width: 8, height: 8), !black)]
        }
    }

    static func decodeMarker(_ image: Raster) -> [UInt8]? {
        let origin = markerOrigin(width: image.width)
        guard origin.x >= 0, origin.y + 64 <= image.height else { return nil }
        var bytes = [UInt8](repeating: 0, count: 12)
        func mean(_ x: Int, _ y: Int) -> Double {
            var sum = 0
            for yy in (y + 2)..<(y + 6) { for xx in (x + 2)..<(x + 6) { sum += Int(image[xx, yy]) } }
            return Double(sum) / 16
        }
        for bit in 0..<96 {
            let x = origin.x + 8 + (bit % 16) * 16, y = origin.y + 8 + (bit / 16) * 8
            let a = mean(x, y), b = mean(x + 8, y)
            if a <= 55 && b >= 200 { bytes[bit / 8] |= 0x80 >> (bit % 8) }
            else if !(a >= 200 && b <= 55) { return nil }
        }
        guard bytes[0] == 0xC7, bytes[1] == 1, (1...6).contains(bytes[10]),
              crc8(Array(bytes.prefix(11))) == bytes[11] else { return nil }
        return bytes
    }

    struct Tile {
        let pass: Bool
        let inkPixels: Int
        let paperPixels: Int
        let referenceContrast: Double
        let balancedMAE: Double
        let contrastRatio: Double
    }

    static func tile(reference: Raster, decoded: Raster, x: Int, y: Int, width: Int, height: Int) -> Tile {
        var ink: [Int] = [], paper: [Int] = []
        for yy in y..<(y + height) {
            for xx in x..<(x + width) {
                let index = yy * reference.width + xx
                if reference.luma[index] <= 96 { ink.append(index) }
                else if reference.luma[index] >= 224 {
                    var nearInk = false
                    for dy in -2...2 {
                        for dx in -2...2 where !nearInk {
                            let nx = xx + dx, ny = yy + dy
                            if nx >= x && nx < x + width && ny >= y && ny < y + height && reference[nx, ny] <= 96 { nearInk = true }
                        }
                    }
                    if nearInk { paper.append(index) }
                }
            }
        }
        guard ink.count >= 16, paper.count >= 16 else {
            return Tile(pass: false, inkPixels: ink.count, paperPixels: paper.count,
                referenceContrast: 0, balancedMAE: 255, contrastRatio: 0)
        }
        func mean(_ values: [UInt8], _ indices: [Int]) -> Double { indices.reduce(0.0) { $0 + Double(values[$1]) } / Double(indices.count) }
        func error(_ indices: [Int]) -> Double { indices.reduce(0.0) { $0 + Double(abs(Int(reference.luma[$1]) - Int(decoded.luma[$1]))) } / Double(indices.count) }
        let contrast = mean(reference.luma, paper) - mean(reference.luma, ink)
        let decodedContrast = mean(decoded.luma, paper) - mean(decoded.luma, ink)
        let mae = (error(ink) + error(paper)) / 2
        let ratio = contrast > 0 ? decodedContrast / contrast : 0
        return Tile(pass: contrast >= 160 && mae <= maximumBalancedMAE && ratio >= minimumContrastRatio,
            inkPixels: ink.count, paperPixels: paper.count, referenceContrast: contrast, balancedMAE: mae, contrastRatio: ratio)
    }

    struct Result {
        let markerPass: Bool
        let textPass: Bool
        let headingPass: Bool
        let stripePass: Bool
        let compositionPass: Bool
        let evidence: [String: Any]
        var pass: Bool { markerPass && textPass && headingPass && stripePass && compositionPass }
    }

    static func assess(reference: Raster, decoded: Raster, expectedPayload: [UInt8], composed: Bool) throws -> Result {
        guard reference.width == decoded.width, reference.height == decoded.height,
              reference.width >= 1100, reference.height >= 800 else { throw Failure.dimensions }
        let referenceMarker = decodeMarker(reference), decodedMarker = decodeMarker(decoded)
        let markerPass = referenceMarker == expectedPayload && decodedMarker == expectedPayload
        var details: [Tile] = []
        for row in 0..<22 {
            for column in 0..<13 {
                details.append(tile(reference: reference, decoded: decoded, x: 32 + column * 64,
                    y: 105 + row * 25, width: 64, height: row == 21 ? 20 : 25))
            }
        }
        let heading = (0..<12).map { tile(reference: reference, decoded: decoded,
            x: 32 + $0 * 64, y: 40, width: 64, height: 48) }
        var referenceStripeContrasts: [Double] = [], stripeRatios: [Double] = []
        for x in stride(from: 32, to: 1096, by: 4) {
            var referenceBlack = 0.0, referenceWhite = 0.0, decodedBlack = 0.0, decodedWhite = 0.0
            for y in (reference.height - 40)..<(reference.height - 20) {
                for dx in 0..<2 {
                    referenceBlack += Double(reference[x + dx, y]); decodedBlack += Double(decoded[x + dx, y])
                    referenceWhite += Double(reference[x + 2 + dx, y]); decodedWhite += Double(decoded[x + 2 + dx, y])
                }
            }
            let contrast = (referenceWhite - referenceBlack) / 40
            referenceStripeContrasts.append(contrast)
            stripeRatios.append(contrast > 0 ? ((decodedWhite - decodedBlack) / 40) / contrast : 0)
        }
        let stripePass = referenceStripeContrasts.allSatisfy { $0 >= 96 } && stripeRatios.allSatisfy { $0 >= minimumContrastRatio }
        let interior = [0.2, 0.5, 0.8].flatMap { x in [0.2, 0.5, 0.8].map { y in (0.77 + 0.20 * x, 0.65 + 0.25 * y) } }
        let outside = [(0.75, 0.775), (0.99, 0.775), (0.87, 0.63), (0.87, 0.92)]
        func composition(_ raster: Raster) -> Bool {
            interior.allSatisfy { raster.green($0.0, $0.1) == composed } && outside.allSatisfy { !raster.green($0.0, $0.1) }
        }
        let compositionPass = composition(reference) && composition(decoded)
        let textPass = details.count == 286 && details.allSatisfy(\.pass)
        let headingPass = heading.allSatisfy(\.pass)
        let evidence: [String: Any] = ["method": method, "markerPass": markerPass,
            "referenceMarkerPass": referenceMarker == expectedPayload, "decodedMarkerPass": decodedMarker == expectedPayload,
            "expectedPayloadHex": expectedPayload.map { String(format: "%02x", $0) }.joined(),
            "textRasterPass": textPass, "headingRasterPass": headingPass, "stripePass": stripePass, "compositionRasterPass": compositionPass,
            "tileCount": details.count, "failedTiles": details.enumerated().filter { !$0.element.pass }.map(\.offset),
            "maximumTileBalancedMAE": details.map(\.balancedMAE).max() ?? 255,
            "minimumTileContrastRatio": details.map(\.contrastRatio).min() ?? 0,
            "minimumReferenceTileContrast": details.map(\.referenceContrast).min() ?? 0,
            "minimumInkPixels": details.map(\.inkPixels).min() ?? 0, "minimumPaperPixels": details.map(\.paperPixels).min() ?? 0,
            "maximumHeadingBalancedMAE": heading.map(\.balancedMAE).max() ?? 255, "minimumHeadingContrastRatio": heading.map(\.contrastRatio).min() ?? 0,
            "stripePeriods": stripeRatios.count, "minimumReferenceStripeContrast": referenceStripeContrasts.min() ?? 0, "minimumStripeContrastRatio": stripeRatios.min() ?? 0,
            "maximumAllowedBalancedMAE": maximumBalancedMAE, "minimumAllowedContrastRatio": minimumContrastRatio]
        return Result(markerPass: markerPass, textPass: textPass, headingPass: headingPass, stripePass: stripePass, compositionPass: compositionPass, evidence: evidence)
    }
}
