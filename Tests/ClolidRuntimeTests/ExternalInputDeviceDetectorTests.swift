import ClolidCore
import XCTest
@testable import ClolidRuntime

final class ExternalInputDeviceDetectorTests: XCTestCase {
    func testDetectsBluetoothKeyboardAndUSBMouse() {
        let detector = makeDetector(
            devices: [
                device(page: 0x01, usage: 0x06, transport: "Bluetooth Low Energy"),
                device(page: 0x01, usage: 0x02, isBuiltIn: false, transport: "USB")
            ]
        )

        let result = detector.detect()

        XCTAssertEqual(result.keyboard, .present)
        XCTAssertEqual(result.pointingDevice, .present)
    }

    func testBuiltInSPIKeyboardAndTrackpadAreAbsent() {
        let detector = makeDetector(
            devices: [
                device(page: 0x01, usage: 0x06, isBuiltIn: true, transport: "SPI"),
                device(page: 0x0D, usage: 0x05, isBuiltIn: true, transport: "SPI")
            ]
        )

        let result = detector.detect()

        XCTAssertEqual(result.keyboard, .absent)
        XCTAssertEqual(result.pointingDevice, .absent)
    }

    func testExplicitBuiltInStateOverridesExternalTransport() {
        let detector = makeDetector(
            devices: [
                device(page: 0x01, usage: 0x06, isBuiltIn: true, transport: "Bluetooth")
            ]
        )

        XCTAssertEqual(detector.detect().keyboard, .absent)
    }

    func testExternalTrackpadCountsAsPointingDevice() {
        let detector = makeDetector(
            devices: [
                device(page: 0x0D, usage: 0x05, isBuiltIn: false, transport: "BluetoothLowEnergy")
            ]
        )

        XCTAssertEqual(detector.detect().pointingDevice, .present)
    }

    func testAmbiguousMatchingDeviceIsUnknown() {
        let detector = makeDetector(
            devices: [
                device(page: 0x01, usage: 0x06, isBuiltIn: false, transport: "Virtual")
            ]
        )

        guard case .unknown(let reason) = detector.detect().keyboard else {
            return XCTFail("Expected an unknown keyboard state.")
        }
        XCTAssertTrue(reason.contains("physical and external"))
    }

    func testUnrelatedDevicesDoNotCountAsExternalInput() {
        let detector = makeDetector(
            devices: [
                device(page: 0x0C, usage: 0x01, isBuiltIn: false, transport: "USB")
            ]
        )

        let result = detector.detect()

        XCTAssertEqual(result.keyboard, .absent)
        XCTAssertEqual(result.pointingDevice, .absent)
    }

    func testUsagePairsRecognizeCompoundDeviceRoles() {
        let detector = makeDetector(
            devices: [
                HIDDeviceRecord(
                    usagePairs: [
                        HIDUsagePair(page: 0x01, usage: 0x06),
                        HIDUsagePair(page: 0x01, usage: 0x02)
                    ],
                    isBuiltIn: false,
                    transport: "USB"
                )
            ]
        )

        let result = detector.detect()

        XCTAssertEqual(result.keyboard, .present)
        XCTAssertEqual(result.pointingDevice, .present)
    }

    func testIncompleteExternalUsageMetadataIsUnknown() {
        let detector = makeDetector(
            devices: [
                HIDDeviceRecord(
                    usagePairs: [],
                    usageMetadataComplete: false,
                    isBuiltIn: false,
                    transport: "USB"
                )
            ]
        )

        let result = detector.detect()

        guard case .unknown = result.keyboard else {
            return XCTFail("Expected an unknown keyboard state.")
        }
        guard case .unknown = result.pointingDevice else {
            return XCTFail("Expected an unknown pointing-device state.")
        }
    }

    func testInventoryFailureMakesBothStatesUnknown() {
        let detector = ExternalInputDeviceDetector(provider: FailingHIDInventory())

        let result = detector.detect()

        XCTAssertEqual(result.keyboard, .unknown(reason: "Inventory test failure."))
        XCTAssertEqual(result.pointingDevice, .unknown(reason: "Inventory test failure."))
    }

    private func makeDetector(devices: [HIDDeviceRecord]) -> ExternalInputDeviceDetector {
        ExternalInputDeviceDetector(provider: StubHIDInventory(records: devices))
    }

    private func device(
        page: Int,
        usage: Int,
        isBuiltIn: Bool? = nil,
        transport: String?
    ) -> HIDDeviceRecord {
        HIDDeviceRecord(
            usagePairs: [HIDUsagePair(page: page, usage: usage)],
            isBuiltIn: isBuiltIn,
            transport: transport
        )
    }
}

private struct StubHIDInventory: HIDDeviceInventoryProviding {
    let records: [HIDDeviceRecord]

    func devices() throws -> [HIDDeviceRecord] {
        records
    }
}

private enum HIDInventoryTestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Inventory test failure."
    }
}

private struct FailingHIDInventory: HIDDeviceInventoryProviding {
    func devices() throws -> [HIDDeviceRecord] {
        throw HIDInventoryTestError.failed
    }
}
