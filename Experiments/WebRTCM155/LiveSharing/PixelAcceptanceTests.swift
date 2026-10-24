import Foundation
import Darwin

/// Held real transport images plus destructive pixel controls; no capture or meeting.
@main struct PixelAcceptanceTests {
    typealias Raster = SharingPixelAcceptance.Raster
    static var checks = 0
    static let nonce: [UInt8] = [16, 17, 18, 19, 20, 21, 22, 23]
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
        checks += 1
    }
    static func paint(_ image: inout Raster, x: Int, y: Int, width: Int, height: Int, rgb: [UInt8]) {
        for yy in y..<(y + height) { for xx in x..<(x + width) {
            let index = yy * image.width + xx
            image.luma[index] = UInt8((77 * Int(rgb[0]) + 150 * Int(rgb[1]) + 29 * Int(rgb[2])) >> 8)
            for channel in 0..<3 { image.rgba[index * 4 + channel] = rgb[channel] }
        } }
    }
    static func stamp(_ image: inout Raster, _ payload: [UInt8]) {
        for bit in 0..<96 {
            let x = image.width - 296 + (bit % 16) * 16, y = 40 + (bit / 16) * 8
            let blackFirst = payload[bit / 8] & (0x80 >> (bit % 8)) != 0
            for half in 0..<2 {
                let value: UInt8 = (half == 0) == blackFirst ? 0 : 255
                paint(&image, x: x + half * 8, y: y, width: 8, height: 8, rgb: [value, value, value])
            }
        }
    }
    static func main() throws {
        setbuf(stdout, nil)
        let repository = URL(fileURLWithPath: CommandLine.arguments[1])
        let controls = URL(fileURLWithPath: CommandLine.arguments[2])
        let base = repository.appendingPathComponent(".build/webrtc-m155-port/live-validation")
        let corners = try Raster(url: controls.appendingPathComponent("asymmetric-corners.png"))
        func rgb(_ x: Int, _ y: Int) -> [UInt8] { Array(corners.rgba[((y * corners.width + x) * 4)..<((y * corners.width + x) * 4 + 3)]) }
        print("ASYMMETRIC_CORNERS", rgb(1, 1), rgb(14, 1), rgb(1, 14))
        require(rgb(1, 1) == [255, 0, 0] && rgb(14, 1) == [0, 255, 0] && rgb(1, 14) == [0, 0, 255], "Independent asymmetric PNG establishes Raster top-left coordinates")
        require(SharingPixelAcceptance.crc8(Array("123456789".utf8)) == 0xf4, "CRC8 known vector")
        let expected = SharingPixelAcceptance.payload(nonce: nonce, phase: 1)
        var reference = try Raster(url: base.appendingPathComponent("sharing-h264-r10/reference-screen-static.png"))
        var decoded = try Raster(url: base.appendingPathComponent("sharing-h264-r10/decoded-screen-static.png"))
        let historicalH264 = try SharingPixelAcceptance.assess(reference: reference, decoded: decoded, expectedPayload: expected, composed: false)
        print("HISTORICAL_H264_NO_MARKER", historicalH264.evidence)
        require(!historicalH264.markerPass && historicalH264.textPass && historicalH264.headingPass && historicalH264.stripePass && historicalH264.compositionPass,
                "Historical H264 has quality evidence only; no transported nonce marker")
        stamp(&reference, expected); stamp(&decoded, expected)
        func assess(_ candidate: Raster, composed: Bool = false, ref: Raster? = nil) throws -> SharingPixelAcceptance.Result {
            try SharingPixelAcceptance.assess(reference: ref ?? reference, decoded: candidate, expectedPayload: expected, composed: composed)
        }
        let h264 = try assess(decoded)
        print("H264", h264.evidence)
        require(h264.pass, "Held H264 quality positive with independently stamped synthetic marker")
        for phase in 1...6 {
            let value = SharingPixelAcceptance.payload(nonce: nonce, phase: UInt8(phase))
            var image = decoded; stamp(&image, value)
            require(SharingPixelAcceptance.decodeMarker(image) == value, "All six phases decode")
            for wrong in 1...6 where wrong != phase {
                var wrongImage = decoded; stamp(&wrongImage, SharingPixelAcceptance.payload(nonce: nonce, phase: UInt8(wrong)))
                var phaseReference = reference; stamp(&phaseReference, value)
                let result = try SharingPixelAcceptance.assess(reference: phaseReference, decoded: wrongImage, expectedPayload: value, composed: false)
                require(!result.markerPass && result.evidence["referenceMarkerPass"] as? Bool == true && result.evidence["decodedMarkerPass"] as? Bool == false &&
                        result.textPass && result.headingPass && result.stripePass && result.compositionPass,
                        "All30 wrong-phase pairs reject specifically by decoded marker, despite correct reference and quality")
            }
        }
        var wrongNonce = decoded
        stamp(&wrongNonce, SharingPixelAcceptance.payload(nonce: nonce.map { $0 ^ 0xff }, phase: 1))
        require(try !assess(wrongNonce).markerPass, "Valid-CRC stale nonce rejects")
        var badCRC = expected; badCRC[11] ^= 1
        var corrupt = decoded; stamp(&corrupt, badCRC)
        require(SharingPixelAcceptance.decodeMarker(corrupt) == nil, "Altered CRC rejects")
        for value: UInt8 in [0, 127, 255] {
            var pair = decoded
            paint(&pair, x: pair.width - 296, y: 40, width: 16, height: 8, rgb: [value, value, value])
            require(SharingPixelAcceptance.decodeMarker(pair) == nil, "Noncomplementary/midgray cell pair rejects")
        }
        var oldImage = try Raster(url: base.appendingPathComponent("sharing-vp8-r9b/decoded-screen-static.png"))
        require(SharingPixelAcceptance.decodeMarker(oldImage) == nil, "Real old-phase image without nonce rejects")
        stamp(&oldImage, expected)
        for row in 0..<22 {
            var erased = decoded
            paint(&erased, x: 32, y: 105 + row * 25, width: 832, height: row == 21 ? 20 : 25, rgb: [255, 255, 255])
            let result = try assess(erased)
            require(!result.textPass && result.markerPass, "Each individually whitened fine-text row rejects by text gate")
        }
        var erasedTile = decoded
        paint(&erasedTile, x: 32 + 6 * 64, y: 105 + 10 * 25, width: 64, height: 25, rgb: [255, 255, 255])
        require(try !assess(erasedTile).textPass, "One erased64px tile rejects")
        for value: UInt8 in [0, 255] {
            var blank = decoded
            paint(&blank, x: 32, y: 105, width: 832, height: 545, rgb: [value, value, value])
            let result = try assess(blank)
            require(!result.textPass && result.markerPass, "Black/blank text rejects by text gate")
            var blankReference = reference
            paint(&blankReference, x: 32, y: 105, width: 832, height: 545, rgb: [value, value, value])
            require(try !assess(blank, ref: blankReference).textPass, "Matching blank/black source and decoded text fails reference-mask guards")
        }
        var heading = decoded
        paint(&heading, x: 32, y: 40, width: 768, height: 48, rgb: [255, 255, 255])
        require(try !assess(heading).headingPass, "Erased heading rejects")
        let replaced = try Raster(url: base.appendingPathComponent("sharing-vp8-r9b/decoded-screen-resized.png"))
        var replacedHeading = decoded
        for y in 40..<88 { for x in 32..<800 { replacedHeading.luma[y * decoded.width + x] = replaced[x, y] } }
        require(try !assess(replacedHeading).headingPass, "Real different-phase heading rejects by heading gate")
        for name in ["blur1", "half-resolution"] {
            var degraded = try Raster(url: controls.appendingPathComponent("\(name).png")); stamp(&degraded, expected)
            let result = try assess(degraded)
            require(!result.textPass && result.markerPass, "\(name) rejects by text gate, not marker")
            require(!result.stripePass, "\(name) rejects two-pixel stripe detail")
        }
        let names = ["screen-static", "screen-resized", "presenter-card", "presenter-resumed", "receiver-reconnected", "sender-reconnected"]
        for (index, name) in names.enumerated() {
            var ref = try Raster(url: base.appendingPathComponent("sharing-vp8-r9b/reference-\(name).png"))
            var image = try Raster(url: base.appendingPathComponent("sharing-vp8-r9b/decoded-\(name).png"))
            let historical = try assess(image, composed: index >= 2, ref: ref)
            print("HISTORICAL_VP8_NO_MARKER", name, historical.evidence)
            require(!historical.markerPass && historical.textPass && historical.headingPass && historical.stripePass && historical.compositionPass,
                    "Historical VP8 has quality evidence only; no transported nonce marker")
            stamp(&ref, expected); stamp(&image, expected)
            let result = try assess(image, composed: index >= 2, ref: ref)
            require(result.pass, "Held VP8 \(name) quality positive; synthetic marker separate from historical live acceptance")
            if name == "presenter-card" {
                for kind in ["missing", "shifted", "wrong-color", "center-only"] {
                    var changed = image
                    paint(&changed, x: Int(0.77 * Double(image.width)), y: Int(0.65 * Double(image.height)),
                        width: Int(0.20 * Double(image.width)), height: Int(0.25 * Double(image.height)), rgb: [255, 255, 255])
                    if kind == "shifted" { paint(&changed, x: 600, y: 520, width: 240, height: 180, rgb: [20, 205, 71]) }
                    if kind == "wrong-color" { paint(&changed, x: 924, y: 520, width: 240, height: 200, rgb: [205, 20, 71]) }
                    if kind == "center-only" {
                        paint(&changed, x: Int(0.87 * Double(image.width)) - 2, y: Int(0.775 * Double(image.height)) - 2,
                            width: 5, height: 5, rgb: [20, 205, 71])
                        require(changed.green(0.87, 0.775), "Center-only spoof satisfies the original single-point sample")
                    }
                    let result = try assess(changed, composed: true, ref: ref)
                    require(!result.compositionPass && result.markerPass, "\(kind) composition rejects by composition gate")
                }
            }
        }
        print("PASS: \(checks) deterministic marker, held-image quality and destructive-negative checks; no live capture or OCR")
    }
}
