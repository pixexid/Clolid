import Foundation

public protocol WakePulseControlling: AnyObject {
    var isRunning: Bool { get }
    func issue(duration: TimeInterval) throws
    func stop()
}

public final class WakePulseController: WakePulseControlling {
    public var isRunning: Bool {
        activeProcess?.isRunning == true
    }

    private let executableURL: URL
    private let launcher: any AssertionProcessLaunching
    private var activeProcess: (any ManagedAssertionProcess)?

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/caffeinate"),
        launcher: any AssertionProcessLaunching = FoundationAssertionProcessLauncher()
    ) {
        self.executableURL = executableURL
        self.launcher = launcher
    }

    public func issue(duration: TimeInterval) throws {
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
