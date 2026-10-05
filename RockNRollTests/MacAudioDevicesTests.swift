import XCTest
@testable import RockNRoll

@MainActor
final class MacAudioDevicesTests: XCTestCase {
    private final class Hardware: MacAudioHardware {
        var value = MacAudioSnapshot(devices: [
            MacAudioDevice(id: 10, name: "Display", directions: [.output]),
            MacAudioDevice(id: 20, name: "USB headset", directions: [.output, .input]),
            MacAudioDevice(id: 30, name: "Microphone", directions: [.input])
        ], outputID: 10, inputID: 30)
        var selected: [(UInt32, MacAudioDirection)] = []
        var changed: (@MainActor () -> Void)?
        var fail = false
        var asynchronous = false
        func snapshot() throws -> MacAudioSnapshot {
            if fail { throw MacAudioError.unavailable }
            return value
        }
        func select(_ id: UInt32, for direction: MacAudioDirection) throws {
            if fail { throw MacAudioError.unavailable }
            selected.append((id, direction))
            if !asynchronous {
                if direction == .output { value.outputID = id } else { value.inputID = id }
                changed?()
            }
        }
        func observe(_ changed: @escaping @MainActor () -> Void) { self.changed = changed }
    }

    func testListsOnlyDevicesForTheRequestedDirection() {
        let devices = MacAudioDevices(isMac: true, hardware: Hardware())
        XCTAssertEqual(devices.snapshot.devices(for: .output).map(\.id), [10, 20])
        XCTAssertEqual(devices.snapshot.devices(for: .input).map(\.id), [20, 30])
        XCTAssertEqual(devices.snapshot.outputName, "Display")
    }

    func testSelectingOutputDoesNotChangeInputAndViceVersa() throws {
        let hardware = Hardware()
        let devices = MacAudioDevices(isMac: true, hardware: hardware)
        try devices.select(20, for: .output)
        XCTAssertEqual(devices.snapshot.outputID, 20)
        XCTAssertEqual(devices.snapshot.inputID, 30)
        try devices.select(20, for: .input)
        XCTAssertEqual(devices.snapshot.inputID, 20)
        XCTAssertEqual(devices.snapshot.outputID, 20)
    }

    func testRejectsDisconnectedAndWrongDirectionDevices() {
        let hardware = Hardware()
        let devices = MacAudioDevices(isMac: true, hardware: hardware)
        XCTAssertThrowsError(try devices.select(30, for: .output))
        hardware.value.devices.removeAll { $0.id == 20 }
        XCTAssertThrowsError(try devices.select(20, for: .output))
        XCTAssertTrue(hardware.selected.isEmpty)
        XCTAssertFalse(devices.snapshot.devices.contains { $0.id == 20 })
    }

    func testAlreadySelectedRouteIsNotRestarted() throws {
        let hardware = Hardware()
        let devices = MacAudioDevices(isMac: true, hardware: hardware)
        try devices.select(10, for: .output)
        XCTAssertTrue(hardware.selected.isEmpty)
    }

    func testAsynchronousCheckmarkFollowsHardwareNotification() throws {
        let hardware = Hardware()
        hardware.asynchronous = true
        let devices = MacAudioDevices(isMac: true, hardware: hardware)
        try devices.select(20, for: .output)
        XCTAssertEqual(devices.snapshot.outputID, 10)
        hardware.value.outputID = 20
        hardware.changed?()
        XCTAssertEqual(devices.snapshot.outputID, 20)
    }

    func testExternalRouteAndDeviceChangesRefreshTheList() {
        let hardware = Hardware()
        let devices = MacAudioDevices(isMac: true, hardware: hardware)
        hardware.value.devices.removeAll { $0.id == 10 }
        hardware.value.outputID = 20
        hardware.changed?()
        XCTAssertEqual(devices.snapshot.devices(for: .output).map(\.id), [20])
        XCTAssertEqual(devices.snapshot.outputName, "USB headset")
    }

    func testHardwareFailurePreservesSelectionAndReportsUnavailable() {
        let hardware = Hardware()
        let devices = MacAudioDevices(isMac: true, hardware: hardware)
        hardware.fail = true
        XCTAssertThrowsError(try devices.select(20, for: .output))
        devices.refresh()
        XCTAssertTrue(devices.unavailable)
        XCTAssertTrue(devices.snapshot.devices.isEmpty)
        XCTAssertEqual(hardware.value.outputID, 10)
    }

    func testPhoneDoesNotObserveOrWriteMacHardware() {
        let hardware = Hardware()
        let devices = MacAudioDevices(isMac: false, hardware: hardware)
        XCTAssertNil(hardware.changed)
        XCTAssertTrue(devices.snapshot.devices.isEmpty)
        XCTAssertThrowsError(try devices.select(20, for: .output))
        XCTAssertTrue(hardware.selected.isEmpty)
    }
}
