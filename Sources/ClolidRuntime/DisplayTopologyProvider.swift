import ClolidCore
import CoreGraphics
import Foundation

public protocol DisplayTopologyProviding {
    func snapshot(at observedAt: Date) throws -> DisplayTopology
}

public enum DisplayTopologyProviderError: LocalizedError {
    case enumerationFailed(CGError)

    public var errorDescription: String? {
        switch self {
        case .enumerationFailed(let error):
            return "Unable to read the current display topology (CoreGraphics error \(error.rawValue))."
        }
    }
}

public struct CoreGraphicsDisplayTopologyProvider: DisplayTopologyProviding {
    public init() {}

    public func snapshot(at observedAt: Date = Date()) throws -> DisplayTopology {
        var displayCount: UInt32 = 0
        let countResult = CGGetOnlineDisplayList(0, nil, &displayCount)
        guard countResult == .success else {
            throw DisplayTopologyProviderError.enumerationFailed(countResult)
        }

        guard displayCount > 0 else {
            return DisplayTopology(observedAt: observedAt, displays: [])
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let listResult = CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)
        guard listResult == .success else {
            throw DisplayTopologyProviderError.enumerationFailed(listResult)
        }

        let displays = displayIDs.prefix(Int(displayCount)).map { displayID in
            let bounds = CGDisplayBounds(displayID)
            let pixelWidth = CGDisplayPixelsWide(displayID)
            let pointWidth = bounds.width
            let scale = pointWidth > 0 ? Double(pixelWidth) / pointWidth : nil

            return DisplayDescriptor(
                id: displayID,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                isOnline: CGDisplayIsOnline(displayID) != 0,
                isActive: CGDisplayIsActive(displayID) != 0,
                isMain: CGDisplayIsMain(displayID) != 0,
                isMirrored: CGDisplayIsInMirrorSet(displayID) != 0,
                width: pixelWidth,
                height: CGDisplayPixelsHigh(displayID),
                scale: scale
            )
        }

        return DisplayTopology(observedAt: observedAt, displays: displays)
    }
}

public protocol DisplayTopologyMonitoring: AnyObject {
    func start(handler: @escaping () -> Void) throws
    func stop()
}

public enum DisplayTopologyMonitorError: LocalizedError {
    case registrationFailed(CGError)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let error):
            return "Unable to monitor display changes (CoreGraphics error \(error.rawValue))."
        }
    }
}

public final class CoreGraphicsDisplayTopologyMonitor: DisplayTopologyMonitoring {
    private var handler: (() -> Void)?
    private var isRegistered = false

    public init() {}

    deinit {
        stop()
    }

    public func start(handler: @escaping () -> Void) throws {
        self.handler = handler
        guard !isRegistered else {
            return
        }

        let result = CGDisplayRegisterReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard result == .success else {
            self.handler = nil
            throw DisplayTopologyMonitorError.registrationFailed(result)
        }
        isRegistered = true
    }

    public func stop() {
        guard isRegistered else {
            handler = nil
            return
        }

        CGDisplayRemoveReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        isRegistered = false
        handler = nil
    }

    fileprivate func displayConfigurationDidChange(flags: CGDisplayChangeSummaryFlags) {
        guard !flags.contains(.beginConfigurationFlag), let handler else {
            return
        }
        DispatchQueue.main.async(execute: handler)
    }
}

private func displayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else {
        return
    }

    let monitor = Unmanaged<CoreGraphicsDisplayTopologyMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    monitor.displayConfigurationDidChange(flags: flags)
}
