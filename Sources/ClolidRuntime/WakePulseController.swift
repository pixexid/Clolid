import CoreGraphics
import Foundation

public protocol WakePulseControlling: AnyObject {
    var isRunning: Bool { get }
    @discardableResult
    func prepareRecoveryInputAccess() -> Bool
    func issue(duration: TimeInterval) throws
    func issueRecovery(duration: TimeInterval) throws
    func stop()
}

public protocol RecoveryInputPosting {
    @discardableResult
    func requestAccess() -> Bool
    func postNudge() throws
}

public struct CoreGraphicsRecoveryInputPoster: RecoveryInputPosting {
    public init() {}

    @discardableResult
    public func requestAccess() -> Bool {
        CGRequestPostEventAccess()
    }

    public func postNudge() throws {
        guard CGPreflightPostEventAccess() else {
            throw WakePulseControllerError.recoveryInputAccessDenied
        }
        guard let currentEvent = CGEvent(source: nil) else {
            throw WakePulseControllerError.unableToCreateRecoveryInput
        }

        let originalLocation = currentEvent.location
        let nudgedLocation = CGPoint(x: originalLocation.x + 1, y: originalLocation.y)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let nudge = CGEvent(
                  mouseEventSource: source,
                  mouseType: .mouseMoved,
                  mouseCursorPosition: nudgedLocation,
                  mouseButton: .left
              ),
              let restore = CGEvent(
                  mouseEventSource: source,
                  mouseType: .mouseMoved,
                  mouseCursorPosition: originalLocation,
                  mouseButton: .left
              ) else {
            throw WakePulseControllerError.unableToCreateRecoveryInput
        }

        nudge.post(tap: .cghidEventTap)
        restore.post(tap: .cghidEventTap)
    }
}

public enum WakePulseControllerError: LocalizedError {
    case recoveryInputAccessDenied
    case unableToCreateRecoveryInput

    public var errorDescription: String? {
        switch self {
        case .recoveryInputAccessDenied:
            return "Accessibility permission is required to recover an external display after lid close."
        case .unableToCreateRecoveryInput:
            return "Unable to create the recovery input event."
        }
    }
}

public final class WakePulseController: WakePulseControlling {
    public var isRunning: Bool {
        activeProcess?.isRunning == true
    }

    private let executableURL: URL
    private let launcher: any AssertionProcessLaunching
    private let recoveryInputPoster: any RecoveryInputPosting
    private var activeProcess: (any ManagedAssertionProcess)?

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/caffeinate"),
        launcher: any AssertionProcessLaunching = FoundationAssertionProcessLauncher(),
        recoveryInputPoster: any RecoveryInputPosting = CoreGraphicsRecoveryInputPoster()
    ) {
        self.executableURL = executableURL
        self.launcher = launcher
        self.recoveryInputPoster = recoveryInputPoster
    }

    @discardableResult
    public func prepareRecoveryInputAccess() -> Bool {
        recoveryInputPoster.requestAccess()
    }

    public func issue(duration: TimeInterval) throws {
        try replacePulse(duration: duration)
    }

    public func issueRecovery(duration: TimeInterval) throws {
        try replacePulse(duration: duration)
        try recoveryInputPoster.postNudge()
    }

    private func replacePulse(duration: TimeInterval) throws {
        let seconds = max(1, Int(duration.rounded(.up)))
        let replacement = try launcher.launch(
            executableURL: executableURL,
            arguments: ["-u", "-t", "\(seconds)"]
        )
        guard replacement.isRunning else {
            replacement.terminate()
            throw SessionAssertionControllerError.processDidNotStart
        }

        let previous = activeProcess
        activeProcess = replacement
        previous?.terminate()
    }

    public func stop() {
        activeProcess?.terminate()
        activeProcess = nil
    }
}
