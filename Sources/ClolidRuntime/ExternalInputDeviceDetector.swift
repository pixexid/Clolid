import ClolidCore
import Foundation
import IOKit.hid

public struct HIDUsagePair: Equatable, Hashable, Sendable {
    public let page: Int
    public let usage: Int

    public init(page: Int, usage: Int) {
        self.page = page
        self.usage = usage
    }
}

public struct HIDDeviceRecord: Equatable, Sendable {
    public let usagePairs: Set<HIDUsagePair>
    public let usageMetadataComplete: Bool
    public let isBuiltIn: Bool?
    public let transport: String?

    public init(
        usagePairs: Set<HIDUsagePair>,
        usageMetadataComplete: Bool = true,
        isBuiltIn: Bool?,
        transport: String?
    ) {
        self.usagePairs = usagePairs
        self.usageMetadataComplete = usageMetadataComplete
        self.isBuiltIn = isBuiltIn
        self.transport = transport
    }
}

public protocol HIDDeviceInventoryProviding {
    func devices() throws -> [HIDDeviceRecord]
}

public enum HIDDeviceInventoryError: LocalizedError {
    case managerOpenFailed(IOReturn)
    case enumerationUnavailable

    public var errorDescription: String? {
        switch self {
        case .managerOpenFailed(let result):
            return "External input status is unavailable (IOKit error \(result))."
        case .enumerationUnavailable:
            return "External input status is unavailable because IOKit returned no device inventory."
        }
    }
}

public struct IOKitHIDDeviceInventoryProvider: HIDDeviceInventoryProviding {
    public init() {}

    public func devices() throws -> [HIDDeviceRecord] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x06],
            [kIOHIDDeviceUsagePageKey: 0x01, kIOHIDDeviceUsageKey: 0x02],
            [kIOHIDDeviceUsagePageKey: 0x0D, kIOHIDDeviceUsageKey: 0x05]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw HIDDeviceInventoryError.managerOpenFailed(openResult)
        }
        defer {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        guard let deviceSet = IOHIDManagerCopyDevices(manager) else {
            throw HIDDeviceInventoryError.enumerationUnavailable
        }

        return (deviceSet as NSSet).allObjects.map { object in
            let device = object as! IOHIDDevice
            let usageMetadata = usageMetadata(for: device)
            return HIDDeviceRecord(
                usagePairs: usageMetadata.pairs,
                usageMetadataComplete: usageMetadata.isComplete,
                isBuiltIn: builtInState(for: device),
                transport: stringProperty(kIOHIDTransportKey, for: device)
            )
        }
    }

    private func usageMetadata(
        for device: IOHIDDevice
    ) -> (pairs: Set<HIDUsagePair>, isComplete: Bool) {
        var usagePairs: Set<HIDUsagePair> = []
        var metadataFound = false
        var isComplete = true

        if let rawPairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) {
            metadataFound = true
            if CFGetTypeID(rawPairs) == CFArrayGetTypeID(),
               let pairs = rawPairs as? [[String: Any]] {
                for pair in pairs {
                    guard let page = validatedInteger(pair[kIOHIDDeviceUsagePageKey]),
                          let usage = validatedInteger(pair[kIOHIDDeviceUsageKey]) else {
                        isComplete = false
                        continue
                    }
                    usagePairs.insert(HIDUsagePair(page: page, usage: usage))
                }
            } else {
                isComplete = false
            }
        }

        let rawPrimaryPage = IOHIDDeviceGetProperty(
            device,
            kIOHIDPrimaryUsagePageKey as CFString
        )
        let rawPrimaryUsage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString)
        if rawPrimaryPage != nil || rawPrimaryUsage != nil {
            metadataFound = true
            guard let page = validatedInteger(rawPrimaryPage),
                  let usage = validatedInteger(rawPrimaryUsage) else {
                return (usagePairs, false)
            }
            usagePairs.insert(HIDUsagePair(page: page, usage: usage))
        }

        return (usagePairs, metadataFound && isComplete)
    }

    private func builtInState(for device: IOHIDDevice) -> Bool? {
        guard let rawValue = IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) else {
            return nil
        }
        if CFGetTypeID(rawValue) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((rawValue as! CFBoolean))
        }
        guard CFGetTypeID(rawValue) == CFNumberGetTypeID(),
              let value = rawValue as? NSNumber else {
            return nil
        }
        switch value.intValue {
        case 0:
            return false
        case 1:
            return true
        default:
            return nil
        }
    }

    private func stringProperty(_ key: String, for device: IOHIDDevice) -> String? {
        guard let rawValue = IOHIDDeviceGetProperty(device, key as CFString),
              CFGetTypeID(rawValue) == CFStringGetTypeID() else {
            return nil
        }
        return rawValue as? String
    }

    private func validatedInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID() else {
            return nil
        }
        return number.intValue
    }
}

public struct ExternalInputDeviceDetection: Equatable, Sendable {
    public let keyboard: DetectionState
    public let pointingDevice: DetectionState

    public init(keyboard: DetectionState, pointingDevice: DetectionState) {
        self.keyboard = keyboard
        self.pointingDevice = pointingDevice
    }
}

public struct ExternalInputDeviceDetector {
    private enum InputKind {
        case keyboard
        case pointingDevice

        var displayName: String {
            switch self {
            case .keyboard:
                return "external keyboard"
            case .pointingDevice:
                return "external pointing device"
            }
        }
    }

    private enum DeviceOrigin {
        case external
        case internalDevice
        case unknown
    }

    private let provider: any HIDDeviceInventoryProviding

    public init(provider: any HIDDeviceInventoryProviding = IOKitHIDDeviceInventoryProvider()) {
        self.provider = provider
    }

    public func detect() -> ExternalInputDeviceDetection {
        do {
            let devices = try provider.devices()
            return ExternalInputDeviceDetection(
                keyboard: detectionState(for: .keyboard, in: devices),
                pointingDevice: detectionState(for: .pointingDevice, in: devices)
            )
        } catch {
            let reason = error.localizedDescription
            return ExternalInputDeviceDetection(
                keyboard: .unknown(reason: reason),
                pointingDevice: .unknown(reason: reason)
            )
        }
    }

    private func detectionState(
        for kind: InputKind,
        in devices: [HIDDeviceRecord]
    ) -> DetectionState {
        let matchingDevices = devices.filter { matches(kind, usagePairs: $0.usagePairs) }
        if matchingDevices.contains(where: { origin(of: $0) == .external }) {
            return .present
        }
        if matchingDevices.contains(where: { origin(of: $0) == .unknown }) {
            return .unknown(
                reason: "Clolid could not determine whether a detected \(kind.displayName) is physical and external."
            )
        }
        if devices.contains(where: {
            !$0.usageMetadataComplete && origin(of: $0) != .internalDevice
        }) {
            return .unknown(
                reason: "Clolid could not classify all connected external input-device metadata."
            )
        }
        return .absent
    }

    private func matches(_ kind: InputKind, usagePairs: Set<HIDUsagePair>) -> Bool {
        switch kind {
        case .keyboard:
            return usagePairs.contains(HIDUsagePair(page: 0x01, usage: 0x06))
        case .pointingDevice:
            return usagePairs.contains(HIDUsagePair(page: 0x01, usage: 0x02))
                || usagePairs.contains(HIDUsagePair(page: 0x0D, usage: 0x05))
        }
    }

    private func origin(of device: HIDDeviceRecord) -> DeviceOrigin {
        if device.isBuiltIn == true {
            return .internalDevice
        }

        let normalizedTransport = device.transport?
            .lowercased()
            .filter(\.isLetter)

        switch normalizedTransport {
        case "usb", "bluetooth", "bluetoothlowenergy":
            return .external
        case "spi", "ic":
            return .internalDevice
        default:
            return .unknown
        }
    }
}
