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

    func testPreparationCoalescesSharedVolumeWithoutTriplingTheBudget() throws {
        let estimate = VoicePreparationStorage.estimatedRequiredBytes
        let snapshot = preparationSnapshot(capacities: [estimate + 100, estimate + 50, estimate], shared: true)
        XCTAssertEqual(estimate, 12 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(snapshot.requiredBytes, estimate)
        XCTAssertEqual(snapshot.availableBytes, estimate)
        XCTAssertEqual(snapshot.location, .model)
        XCTAssertNil(snapshot.shortfallBytes)
        XCTAssertNoThrow(try ensurePreparation(capacities: [estimate, estimate, estimate], shared: true))
    }

    func testPreparationReportsTheMostConstrainedCompilerVolume() {
        let estimate = VoicePreparationStorage.estimatedRequiredBytes
        let snapshot = preparationSnapshot(capacities: [estimate + 500, estimate + 100, estimate - 200])
        XCTAssertEqual(snapshot.location, .temporary)
        XCTAssertEqual(snapshot.availableBytes, estimate - 200)
        XCTAssertEqual(snapshot.shortfallBytes, 200)
    }

    func testPreparationChecksCacheVolumeEvenWhenModelAndTemporaryVolumesHaveSpace() {
        let estimate = VoicePreparationStorage.estimatedRequiredBytes
        let snapshot = preparationSnapshot(capacities: [estimate + 500, estimate - 300, estimate + 100])
        XCTAssertEqual(snapshot.location, .model)
        XCTAssertEqual(snapshot.availableBytes, estimate - 300)
        XCTAssertEqual(snapshot.shortfallBytes, 300)
    }

    func testPreparationThrowsTypedErrorOnlyForKnownDeficit() {
        let estimate = VoicePreparationStorage.estimatedRequiredBytes
        XCTAssertThrowsError(try ensurePreparation(capacities: [nil, estimate + 100, estimate - 1])) { error in
            guard let failure = error as? VoicePreparationStorageError else { return XCTFail("Expected preparation-space error") }
            XCTAssertEqual(failure.snapshot.location, .temporary)
            XCTAssertEqual(failure.snapshot.requiredBytes, estimate)
            XCTAssertEqual(failure.snapshot.shortfallBytes, 1)
        }
        XCTAssertNoThrow(try ensurePreparation(capacities: [nil, estimate, nil]))
        XCTAssertNoThrow(try ensurePreparation(capacities: [nil, nil, nil]))
    }

    func testUnknownOrInvalidPreparationCapacityDoesNotInventLowSpace() {
        let snapshot = preparationSnapshot(capacities: [nil, -1, nil])
        XCTAssertNil(snapshot.availableBytes)
        XCTAssertNil(snapshot.location)
        XCTAssertNil(snapshot.shortfallBytes)
        XCTAssertEqual(snapshot.requiredBytes, VoicePreparationStorage.estimatedRequiredBytes)
        XCTAssertNoThrow(try ensurePreparation(capacities: [nil, -1, nil]))
    }

    func testSharedVolumeKeepsKnownReadingWhenAnotherPathCannotBeMeasured() {
        let estimate = VoicePreparationStorage.estimatedRequiredBytes
        let snapshot = preparationSnapshot(capacities: [nil, estimate - 100, nil], shared: true)
        XCTAssertEqual(snapshot.availableBytes, estimate - 100)
        XCTAssertEqual(snapshot.shortfallBytes, 100)
    }

    func testImmediatePreparationCapacityUsesAncestorWithoutCreatingFiles() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("model")
        XCTAssertNotNil(VoicePreparationStorage.immediatelyAvailableCapacity(at: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertNil(VoicePreparationStorage.immediatelyAvailableCapacity(at: URL(string: "https://example.invalid/model")!))
    }

    private let preparationPaths = ["/vol-model/models", "/vol-cache/cache", "/vol-temp/tmp"].map { URL(fileURLWithPath: $0) }

    private func preparationSnapshot(capacities: [Int64?], shared: Bool = false) -> VoiceStorageSnapshot {
        VoicePreparationStorage.snapshot(at: preparationPaths[0], cacheFolder: preparationPaths[1],
            compilerTemporaryFolder: preparationPaths[2], capacity: { capacities[self.preparationPaths.firstIndex(of: $0)!] },
            sameVolume: { _, _ in shared })
    }

    private func ensurePreparation(capacities: [Int64?], shared: Bool = false) throws {
        try VoicePreparationStorage.ensureSpace(at: preparationPaths[0], cacheFolder: preparationPaths[1],
            compilerTemporaryFolder: preparationPaths[2], capacity: { capacities[self.preparationPaths.firstIndex(of: $0)!] },
            sameVolume: { _, _ in shared })
    }
}
