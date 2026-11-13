import Foundation
import XCTest
@testable import RockNativeDesktop

final class VoiceStorageTests: XCTestCase {
    func testOnlyConfirmedNestedOutOfSpaceIsClassifiedAsStorageFailure() {
        let noSpace = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOSPC.rawValue))
        let nested = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                             userInfo: [NSUnderlyingErrorKey: noSpace])
        XCTAssertTrue(VoiceStorage.isOutOfSpace(nested))
        XCTAssertTrue(VoiceStorage.isOutOfSpace(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        XCTAssertFalse(VoiceStorage.isOutOfSpace(NSError(domain: "Foundation._GenericObjCError", code: 0)))
        XCTAssertFalse(VoiceStorage.isOutOfSpace(NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue))))
    }

    func testDestinationEstimateExcludesVerifiedPartialFilesAndAccountsForReplacement() {
        let files: [VoiceStorage.DownloadFile] = [
            .init(bytes: 1_000, existingBytes: 1_000, verified: true),
            .init(bytes: 400, existingBytes: 100, verified: false),
            .init(bytes: 200, existingBytes: 300, verified: false)
        ]
        XCTAssertEqual(VoiceStorage.downloadDestinationMinimum(files), 200)
        XCTAssertEqual(VoiceStorage.downloadDestinationMinimum([.init(bytes: 1, existingBytes: 100, verified: false)]), 0)
        XCTAssertNil(VoiceStorage.downloadDestinationMinimum([.init(bytes: -1, existingBytes: 0, verified: false)]))
        XCTAssertNil(VoiceStorage.downloadDestinationMinimum([
            .init(bytes: Int64.max, existingBytes: 0, verified: false),
            .init(bytes: 1, existingBytes: 0, verified: false)
        ]))
    }

    func testActualTemporaryFileNeedsACopyOnlyAcrossKnownDifferentVolumes() {
        XCTAssertEqual(VoiceStorage.moveRequirement(bytes: 500, sameVolume: true), 0)
        XCTAssertEqual(VoiceStorage.moveRequirement(bytes: 500, sameVolume: false), 500)
        XCTAssertNil(VoiceStorage.moveRequirement(bytes: 500, sameVolume: nil))
        XCTAssertNil(VoiceStorage.moveRequirement(bytes: -1, sameVolume: false))
    }

    func testShortfallRequiresKnownDeficit() {
        XCTAssertEqual(VoiceStorageSnapshot(availableBytes: 200, requiredBytes: 500).shortfallBytes, 300)
        XCTAssertNil(VoiceStorageSnapshot(availableBytes: nil, requiredBytes: 500).shortfallBytes)
        XCTAssertNil(VoiceStorageSnapshot(availableBytes: 200, requiredBytes: nil).shortfallBytes)
        XCTAssertNil(VoiceStorageSnapshot(availableBytes: 500, requiredBytes: 200).shortfallBytes)
    }

    func testCapacityUsesExistingAncestorAndRejectsNonFileURL() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("model")
        XCTAssertNotNil(VoiceStorage.existingAncestor(of: missing))
        XCTAssertNil(VoiceStorage.existingAncestor(of: URL(string: "https://example.invalid/model")!))
        XCTAssertNil(VoiceStorage.capacity(at: URL(string: "https://example.invalid/model")!))
    }
}
