import Combine
import Darwin
import Foundation
#if NATIVE_UPDATE_SAFETY_STANDALONE
// Run the same cases without Xcode's XCTest overlay when only the CLI toolchain is available.
private var standaloneFailures = 0
class XCTestCase {
    private var teardowns: [() -> Void] = []
    func addTeardownBlock(_ block: @escaping () -> Void) { teardowns.append(block) }
    func runTeardowns() { teardowns.reversed().forEach { $0() } }
}
private func fail(_ message: String, _ file: StaticString, _ line: UInt) {
    standaloneFailures += 1
    print("\(file):\(line): error: \(message)")
}
private func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "Expected true",
                          file: StaticString = #filePath, line: UInt = #line) {
    do { if try !value() { fail(message, file, line) } } catch { fail("Unexpected error: \(error)", file, line) }
}
private func XCTAssertFalse(_ value: @autoclosure () throws -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(try !value(), "Expected false", file: file, line: line)
}
private func XCTAssertEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T,
                                        file: StaticString = #filePath, line: UInt = #line) {
    do { if try left() != right() { fail("Values differ", file, line) } } catch { fail("Unexpected error: \(error)", file, line) }
}
private func XCTAssertNil<T>(_ value: @autoclosure () -> T?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value() == nil, "Expected nil", file: file, line: line)
}
private func XCTAssertNotNil<T>(_ value: @autoclosure () -> T?, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value() != nil, "Expected a value", file: file, line: line)
}
private func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, _ handler: ((Error) -> Void)? = nil,
                                    file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try value(); fail("Expected an error", file, line) } catch { handler?(error) }
}
#else
import XCTest
@testable import RockNativeDesktop
#endif

@MainActor final class UpdateSafetyTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-update-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fenceURL(_ directory: URL) -> URL { directory.appendingPathComponent(NativeUpdateSafety.fenceFileName) }

    private func seedFence(_ directory: URL, source: Int = 100, target: Int = 101) throws {
        let safety = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: source)
        try safety.prepareUpdate(targetBuild: target)
    }

    private func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func processCanAcquireLease(_ directory: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MFcntl=:flock", "-e",
                             "open my $lease, '+<', $ARGV[0] or exit 2; flock($lease, LOCK_EX | LOCK_NB) or exit 3; exit 0;",
                             directory.appendingPathComponent(NativeUpdateSafety.lockFileName).path]
        try process.run()
        process.waitUntilExit()
        XCTAssertTrue([0, 3].contains(process.terminationStatus), "The child process must reach the flock check")
        return process.terminationStatus == 0
    }

    func testUnpreparedProcessAdmitsMeetingButCannotReserveInstaller() throws {
        let safety = try NativeUpdateSafety(stateDirectoryURL: directory(), currentBuild: 100)
        XCTAssertTrue(safety.mayStartMeeting)
        XCTAssertThrowsError(try safety.reserveInstallation(busy: false)) { error in
            XCTAssertEqual(error as? NativeUpdateSafety.SafetyError, .updateNotPrepared)
        }
        XCTAssertTrue(safety.mayStartMeeting)
    }

    func testBusyMeetingRejectsReservationAndReservedInstallerRejectsAdmission() throws {
        let safety = try NativeUpdateSafety(stateDirectoryURL: directory(), currentBuild: 100)
        try safety.prepareUpdate(targetBuild: 101)
        XCTAssertTrue(safety.mayStartMeeting)
        XCTAssertFalse(try safety.reserveInstallation(busy: true))
        XCTAssertFalse(safety.installationReserved)
        XCTAssertTrue(safety.mayStartMeeting)
        XCTAssertTrue(try safety.reserveInstallation(busy: false))
        XCTAssertTrue(safety.installationReserved)
        XCTAssertFalse(safety.mayStartMeeting)
        try safety.releaseReservationBeforeInstall()
        XCTAssertTrue(safety.mayStartMeeting)
    }

    func testSynchronousObserversSeeReservationAndAdmissionCommittedTogether() throws {
        let safety = try NativeUpdateSafety(stateDirectoryURL: directory(), currentBuild: 100)
        try safety.prepareUpdate(targetBuild: 101)
        var observedReservation = false
        let observer = safety.objectWillChange.sink {
            observedReservation = safety.installationReserved
            XCTAssertFalse(safety.mayStartMeeting)
        }
        try withExtendedLifetime(observer) {
            XCTAssertTrue(try safety.reserveInstallation(busy: false))
            XCTAssertTrue(observedReservation)
        }
    }

    func testOldBuildRelaunchBlocksAllMeetingsAndDoesNotExpire() throws {
        let directory = try directory()
        try seedFence(directory)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)],
                                             ofItemAtPath: fenceURL(directory).path)
        let safety = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
        XCTAssertEqual(safety.recoveryTargetBuild, 101)
        XCTAssertFalse(safety.mayStartMeeting)
        XCTAssertFalse(try safety.clearPreparedUpdateIfSafe())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fenceURL(directory).path))
    }

    func testTargetBuildAndLaterBuildRetireFenceUnderExclusiveLease() throws {
        for installedBuild in [101, 102] {
            let directory = try directory()
            try seedFence(directory)
            let safety = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: installedBuild)
            XCTAssertNil(safety.recoveryTargetBuild)
            XCTAssertTrue(safety.mayStartMeeting)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fenceURL(directory).path))
        }
    }

    func testRecoveryCanFinishOrRaiseTargetWithoutRegainingMeetingAdmission() throws {
        let directory = try directory()
        try seedFence(directory)
        let safety = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
        try safety.prepareUpdate(targetBuild: 101)
        XCTAssertFalse(try safety.clearPreparedUpdateIfSafe())
        try safety.prepareUpdate(targetBuild: 103)
        XCTAssertEqual(safety.recoveryTargetBuild, 103)
        XCTAssertFalse(safety.mayStartMeeting)
        XCTAssertThrowsError(try safety.prepareUpdate(targetBuild: 102))
        XCTAssertTrue(try safety.reserveInstallation(busy: false))
        safety.releaseReservationAfterVerifiedStage2NotRequested()
        XCTAssertFalse(safety.mayStartMeeting)
        XCTAssertFalse(try safety.clearPreparedUpdateIfSafe())
    }

    func testCancellationOnlyClearsCreatorsFenceBeforeInstallerMayRun() throws {
        let directory = try directory()
        let safety = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
        try safety.prepareUpdate(targetBuild: 101)
        XCTAssertTrue(try safety.reserveInstallation(busy: false))
        XCTAssertTrue(try safety.clearPreparedUpdateIfSafe())
        XCTAssertFalse(safety.installationReserved)
        XCTAssertTrue(safety.mayStartMeeting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fenceURL(directory).path))
        XCTAssertFalse(try safety.clearPreparedUpdateIfSafe())
        try safety.prepareUpdate(targetBuild: 101)
        safety.markInstallerMayRun()
        XCTAssertFalse(try safety.clearPreparedUpdateIfSafe())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fenceURL(directory).path))
    }

    func testInstallerErrorRequiresExplicitProofToReleaseReservationAndNeverClearsFence() throws {
        let directory = try directory()
        var safety: NativeUpdateSafety? = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
        try safety!.prepareUpdate(targetBuild: 101)
        safety!.markInstallerMayRun()
        XCTAssertTrue(try safety!.reserveInstallation(busy: false))
        XCTAssertThrowsError(try safety!.releaseReservationBeforeInstall())
        XCTAssertFalse(try safety!.clearPreparedUpdateIfSafe())
        XCTAssertFalse(safety!.mayStartMeeting)
        safety!.releaseReservationAfterVerifiedStage2NotRequested()
        XCTAssertTrue(safety!.mayStartMeeting)
        XCTAssertFalse(try safety!.clearPreparedUpdateIfSafe())
        safety = nil
        let restarted = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
        XCTAssertFalse(restarted.mayStartMeeting)
        XCTAssertEqual(restarted.recoveryTargetBuild, 101)
    }

    func testProcessLeaseExcludesSameAndOtherProcessesForEntireLifetime() throws {
        let directory = try directory()
        var safety: NativeUpdateSafety? = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
        try withExtendedLifetime(safety) {
            XCTAssertThrowsError(try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)) { error in
                XCTAssertEqual(error as? NativeUpdateSafety.SafetyError, .anotherInstanceRunning)
            }
            XCTAssertFalse(try processCanAcquireLease(directory))
        }
        safety = nil
        XCTAssertTrue(try processCanAcquireLease(directory))
        let next = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
        XCTAssertTrue(next.mayStartMeeting)
    }

    func testCorruptOversizedAndInvalidFenceRecordsFailClosed() throws {
        let invalidRecords = [Data("{".utf8), Data(repeating: 0x20, count: 4_097),
                              Data("{\"version\":1,\"sourceBuild\":100,\"targetBuild\":99,\"identifier\":\"\(UUID().uuidString)\"}".utf8),
                              Data("{\"version\":2,\"sourceBuild\":100,\"targetBuild\":101,\"identifier\":\"\(UUID().uuidString)\"}".utf8)]
        for record in invalidRecords {
            let directory = try directory()
            try privateWrite(record, to: fenceURL(directory))
            XCTAssertThrowsError(try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100))
            XCTAssertEqual(try Data(contentsOf: fenceURL(directory)), record)
        }
    }

    func testSymlinkFenceIsRejectedWithoutTouchingItsTarget() throws {
        let directory = try directory(), outside = try self.directory().appendingPathComponent("protected")
        let original = Data("protected".utf8)
        try privateWrite(original, to: outside)
        try FileManager.default.createSymbolicLink(at: fenceURL(directory), withDestinationURL: outside)
        XCTAssertThrowsError(try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100))
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testSymlinkDirectoryAndLockAreRejected() throws {
        let target = try directory(), parent = try directory()
        let link = parent.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try NativeUpdateSafety(stateDirectoryURL: link, currentBuild: 100))
        let lockTarget = parent.appendingPathComponent("lock-target")
        try privateWrite(Data(), to: lockTarget)
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent(NativeUpdateSafety.lockFileName),
                                                  withDestinationURL: lockTarget)
        XCTAssertThrowsError(try NativeUpdateSafety(stateDirectoryURL: target, currentBuild: 100))
    }

    func testPermissiveDirectoryAndFenceAreRejected() throws {
        let directory = try directory()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try seedFence(directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fenceURL(directory).path)
        XCTAssertThrowsError(try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100))
    }

    func testFailedFenceWriteBlocksUpdateAndAdmission() throws {
        let directory = try directory()
        let safety = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        XCTAssertThrowsError(try safety.prepareUpdate(targetBuild: 101))
        XCTAssertNotNil(safety.storageErrorDescription)
        XCTAssertFalse(safety.mayStartMeeting)
        XCTAssertThrowsError(try safety.reserveInstallation(busy: false))
        XCTAssertFalse(safety.installationReserved)
    }

    func testCancellationCannotEraseAReplacedFence() throws {
        let directory = try directory()
        let safety = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
        try safety.prepareUpdate(targetBuild: 101)
        let replacement = Data("{\"version\":1,\"sourceBuild\":100,\"targetBuild\":102,\"identifier\":\"\(UUID().uuidString)\"}".utf8)
        try privateWrite(replacement, to: fenceURL(directory))
        XCTAssertThrowsError(try safety.clearPreparedUpdateIfSafe())
        XCTAssertEqual(try Data(contentsOf: fenceURL(directory)), replacement)
        XCTAssertFalse(safety.mayStartMeeting)
    }

    func testFencesArePrivateAtomicRecordsAndRepeatedPreparationPreservesIdentity() throws {
        let directory = try directory()
        let safety = try NativeUpdateSafety(stateDirectoryURL: directory, currentBuild: 100)
        try safety.prepareUpdate(targetBuild: 101)
        let data = try Data(contentsOf: fenceURL(directory))
        try safety.prepareUpdate(targetBuild: 101)
        XCTAssertEqual(try Data(contentsOf: fenceURL(directory)), data)
        let attributes = try FileManager.default.attributesOfItem(atPath: fenceURL(directory).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       [NativeUpdateSafety.lockFileName, NativeUpdateSafety.fenceFileName])
    }
}

#if NATIVE_UPDATE_SAFETY_STANDALONE
@main private enum UpdateSafetyTestRunner {
    @MainActor static func main() {
        let tests: [(String, (UpdateSafetyTests) -> () throws -> Void)] = [
            ("testUnpreparedProcessAdmitsMeetingButCannotReserveInstaller", UpdateSafetyTests.testUnpreparedProcessAdmitsMeetingButCannotReserveInstaller),
            ("testBusyMeetingRejectsReservationAndReservedInstallerRejectsAdmission", UpdateSafetyTests.testBusyMeetingRejectsReservationAndReservedInstallerRejectsAdmission),
            ("testSynchronousObserversSeeReservationAndAdmissionCommittedTogether", UpdateSafetyTests.testSynchronousObserversSeeReservationAndAdmissionCommittedTogether),
            ("testOldBuildRelaunchBlocksAllMeetingsAndDoesNotExpire", UpdateSafetyTests.testOldBuildRelaunchBlocksAllMeetingsAndDoesNotExpire),
            ("testTargetBuildAndLaterBuildRetireFenceUnderExclusiveLease", UpdateSafetyTests.testTargetBuildAndLaterBuildRetireFenceUnderExclusiveLease),
            ("testRecoveryCanFinishOrRaiseTargetWithoutRegainingMeetingAdmission", UpdateSafetyTests.testRecoveryCanFinishOrRaiseTargetWithoutRegainingMeetingAdmission),
            ("testCancellationOnlyClearsCreatorsFenceBeforeInstallerMayRun", UpdateSafetyTests.testCancellationOnlyClearsCreatorsFenceBeforeInstallerMayRun),
            ("testInstallerErrorRequiresExplicitProofToReleaseReservationAndNeverClearsFence", UpdateSafetyTests.testInstallerErrorRequiresExplicitProofToReleaseReservationAndNeverClearsFence),
            ("testProcessLeaseExcludesSameAndOtherProcessesForEntireLifetime", UpdateSafetyTests.testProcessLeaseExcludesSameAndOtherProcessesForEntireLifetime),
            ("testCorruptOversizedAndInvalidFenceRecordsFailClosed", UpdateSafetyTests.testCorruptOversizedAndInvalidFenceRecordsFailClosed),
            ("testSymlinkFenceIsRejectedWithoutTouchingItsTarget", UpdateSafetyTests.testSymlinkFenceIsRejectedWithoutTouchingItsTarget),
            ("testSymlinkDirectoryAndLockAreRejected", UpdateSafetyTests.testSymlinkDirectoryAndLockAreRejected),
            ("testPermissiveDirectoryAndFenceAreRejected", UpdateSafetyTests.testPermissiveDirectoryAndFenceAreRejected),
            ("testFailedFenceWriteBlocksUpdateAndAdmission", UpdateSafetyTests.testFailedFenceWriteBlocksUpdateAndAdmission),
            ("testCancellationCannotEraseAReplacedFence", UpdateSafetyTests.testCancellationCannotEraseAReplacedFence),
            ("testFencesArePrivateAtomicRecordsAndRepeatedPreparationPreservesIdentity", UpdateSafetyTests.testFencesArePrivateAtomicRecordsAndRepeatedPreparationPreservesIdentity)
        ]
        for (name, run) in tests {
            let test = UpdateSafetyTests(), previousFailures = standaloneFailures
            do { try run(test)() } catch { fail("\(name): \(error)", #filePath, #line) }
            test.runTeardowns()
            print("\(name): \(standaloneFailures == previousFailures ? "passed" : "failed")")
        }
        print("\(tests.count) tests, \(standaloneFailures) failures")
        exit(standaloneFailures == 0 ? 0 : 1)
    }
}
#endif
