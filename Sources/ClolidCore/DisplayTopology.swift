import Foundation

public struct DisplayDescriptor: Equatable, Sendable {
    public let id: UInt32
    public let name: String?
    public let isBuiltIn: Bool
    public let isOnline: Bool
    public let isActive: Bool
    public let isMain: Bool
    public let isMirrored: Bool
    public let width: Int
    public let height: Int
    public let scale: Double?

    public init(
        id: UInt32,
        name: String? = nil,
        isBuiltIn: Bool,
        isOnline: Bool,
        isActive: Bool,
        isMain: Bool,
        isMirrored: Bool,
        width: Int,
        height: Int,
        scale: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isOnline = isOnline
        self.isActive = isActive
        self.isMain = isMain
        self.isMirrored = isMirrored
        self.width = width
        self.height = height
        self.scale = scale
    }
}

public struct DisplayTopology: Equatable, Sendable {
    public let observedAt: Date
    public let displays: [DisplayDescriptor]

    public init(observedAt: Date, displays: [DisplayDescriptor]) {
        self.observedAt = observedAt
        self.displays = displays
    }

    public var externalOnlineDisplays: [DisplayDescriptor] {
        displays.filter { !$0.isBuiltIn && $0.isOnline }
    }

    public var hasExternalOnlineDisplay: Bool {
        !externalOnlineDisplays.isEmpty
    }

    public var externalActiveDisplays: [DisplayDescriptor] {
        externalOnlineDisplays.filter(\.isActive)
    }

    public var hasActiveExternalDisplay: Bool {
        !externalActiveDisplays.isEmpty
    }

    public var hasMainExternalDisplay: Bool {
        externalOnlineDisplays.contains(where: \.isMain)
    }

    public var externalOnlineDisplayIDs: Set<UInt32> {
        Set(externalOnlineDisplays.map(\.id))
    }
}
