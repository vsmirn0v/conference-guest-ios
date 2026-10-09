import AVFoundation
import LiveKit
import UIKit
import XCTest
@testable import RockNRoll

@MainActor
final class FloatingVideoContentTests: XCTestCase {
    func testCallVideoDefaultPreservesFullCameraAndShareFrame() throws {
        let surface = CallVideoView()
        XCTAssertEqual(surface.layoutMode, .fit)
        let room = try XCTUnwrap(surface.subviews.compactMap { $0 as? VideoView }.first)
        let native = try XCTUnwrap(surface.subviews.compactMap { $0 as? GuestSampleBufferView }.first)
        XCTAssertEqual(room.layoutMode, .fit)
        XCTAssertEqual(native.contentMode, .scaleAspectFit)
        let layer = try XCTUnwrap(native.layer.sublayers?.compactMap { $0 as? AVSampleBufferDisplayLayer }.first)
        XCTAssertEqual(layer.videoGravity, .resizeAspect)
        surface.layoutMode = .fill
        XCTAssertEqual(layer.videoGravity, .resizeAspectFill)
        surface.layoutMode = .fit
        XCTAssertEqual(layer.videoGravity, .resizeAspect)
    }
    func testStatusUpdatesWithoutVideoFramesAndDoesNotReplaceVideo() throws {
        let video = UIView()
        let surface = FloatingVideoContentView(videoContent: video)
        surface.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        let badge = try XCTUnwrap(surface.subviews.first {
            $0.accessibilityIdentifier == "Floating microphone status"
        })
        XCTAssertEqual(badge.accessibilityValue, "Unavailable")
        for (status, expected) in [(PiPMicrophoneStatus.muted, "Muted"), (.on, "On"),
                                    (.unavailable, "Unavailable"), (.muted, "Muted")] {
            surface.setMicrophoneStatus(status)
            surface.layoutIfNeeded()
            XCTAssertEqual(badge.accessibilityLabel, "Your microphone")
            XCTAssertEqual(badge.accessibilityValue, expected)
            XCTAssertFalse(badge.accessibilityTraits.contains(.button))
            XCTAssertFalse(badge.isUserInteractionEnabled)
            XCTAssertTrue(video.superview === surface)
            XCTAssertEqual(video.frame, surface.bounds)
        }
    }

    func testResizingKeepsBadgeVisibleAndRestoresFullLabel() throws {
        let surface = FloatingVideoContentView(videoContent: UIView())
        let badge = try XCTUnwrap(surface.subviews.first {
            $0.accessibilityIdentifier == "Floating microphone status"
        })
        let label = try XCTUnwrap(badge.subviews.compactMap { $0 as? UILabel }.first)
        for status in PiPMicrophoneStatus.allCases {
            surface.setMicrophoneStatus(status)
            for size in [CGSize(width: 320, height: 180), CGSize(width: 144, height: 81),
                         CGSize(width: 144, height: 256), CGSize(width: 320, height: 180)] {
                surface.frame = CGRect(origin: .zero, size: size)
                surface.setNeedsLayout()
                surface.layoutIfNeeded()
                XCTAssertTrue(surface.bounds.contains(badge.frame))
                XCTAssertGreaterThanOrEqual(label.bounds.width, ceil(label.intrinsicContentSize.width))
                XCTAssertEqual(label.text, size.width < 200 ? "You" : status.title)
            }
        }
    }

    func testMicrophoneLayoutGallery() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 860, height: 700))
        let image = renderer.image { context in
            UIColor(white: 0.12, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 860, height: 700))
            for (index, status) in PiPMicrophoneStatus.allCases.enumerated() {
                let top = CGFloat(index) * 225 + 32
                (status.title as NSString).draw(at: CGPoint(x: 16, y: top - 24), withAttributes: [
                    .foregroundColor: UIColor.white, .font: UIFont.systemFont(ofSize: 14)
                ])
                for (size, origin, light) in [
                    (CGSize(width: 320, height: 180), CGPoint(x: 16, y: top), true),
                    (CGSize(width: 320, height: 180), CGPoint(x: 352, y: top), false),
                    (CGSize(width: 144, height: 81), CGPoint(x: 700, y: top), true)
                ] {
                    let video = UIView()
                    video.backgroundColor = light ? .white : UIColor(white: 0.04, alpha: 1)
                    let caption = UILabel(frame: CGRect(x: 8, y: 8, width: size.width - 16, height: 20))
                    caption.text = "Musician · Screen"
                    caption.textColor = light ? .black : .white
                    caption.font = .systemFont(ofSize: 12)
                    video.addSubview(caption)
                    let surface = FloatingVideoContentView(videoContent: video)
                    surface.frame = CGRect(origin: .zero, size: size)
                    surface.setMicrophoneStatus(status)
                    surface.layoutIfNeeded()
                    context.cgContext.saveGState()
                    context.cgContext.translateBy(x: origin.x, y: origin.y)
                    surface.layer.render(in: context.cgContext)
                    context.cgContext.restoreGState()
                }
            }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "PiP microphone layouts"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
