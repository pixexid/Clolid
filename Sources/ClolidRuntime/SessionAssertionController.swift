import ClolidCore
import Darwin
import Foundation

public protocol ManagedAssertionProcess: AnyObject {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    func terminate()
}

extension Process: ManagedAssertionProcess {}

public protocol AssertionProcessLaunching {
    func launch(executableURL: URL, arguments: [String]) throws -> any ManagedAssertionProcess
}

public struct FoundationAssertionProcessLauncher: AssertionProcessLaunching {
    public init() {}

    public func launch(executableURL: URL, arguments: [String]) throws -> any ManagedAssertionProcess {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        try process.run()
        return process
    }
}

public protocol ProcessIdentityChecking {
    func identity(forPID pid: Int32) -> AssertionProcessIdentity?
}

public struct AssertionProcessIdentity: Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64

    public init(
        pid: Int32,
        executablePath: String,
        startTimeSeconds: UInt64,
        startTimeMicroseconds: UInt64
    ) {
        self.pid = pid
        self.executablePath = executablePath
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

public struct SystemProcessIdentityChecker: ProcessIdentityChecking {
    public init() {}

    public func identity(forPID pid: Int32) -> AssertionProcessIdentity? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return nil
        }

        var processInfo = proc_bsdinfo()
        let processInfoSize = MemoryLayout<proc_bsdinfo>.stride
        let bytesWritten = withUnsafeMutablePointer(to: &processInfo) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(processInfoSize)
            )
        }
        guard bytesWritten == processInfoSize else {
            return nil
        }

        return AssertionProcessIdentity(
            pid: pid,
            executablePath: String(cString: buffer),
            startTimeSeconds: processInfo.pbi_start_tvsec,
            startTimeMicroseconds: processInfo.pbi_start_tvusec
        )
    }
}

public protocol ProcessSignaling {
    @discardableResult
    func terminate(pid: Int32) -> Bool
}

public struct DarwinProcessSignaler: ProcessSignaling {
    public init() {}

    @discardableResult
    public func terminate(pid: Int32) -> Bool {
        Darwin.kill(pid, SIGTERM) == 0
    }
}

public enum SessionAssertionControllerError: LocalizedError {
    case processDidNotStart
    case processIdentityUnavailable

    public var errorDescription: String? {
        switch self {
        case .processDidNotStart:
            return "The caffeinate assertion process did not stay running."
        case .processIdentityUnavailable:
            return "Clolid could not verify ownership of the caffeinate assertion process."
        }
    }
}

public final class SessionAssertionController {
    public private(set) var activePID: Int32?
    public private(set) var activeArguments: [String] = []
    public var isRunning: Bool {
        activeProcess?.isRunning == true
    }

    private let executableURL: URL
    private let pidFileURL: URL
    private let launcher: any AssertionProcessLaunching
    private let identityChecker: any ProcessIdentityChecking
    private let signaler: any ProcessSignaling
    private let fileManager: FileManager
    private var activeProcess: (any ManagedAssertionProcess)?

    public init(
        pidFileURL: URL,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/caffeinate"),
        launcher: any AssertionProcessLaunching = FoundationAssertionProcessLauncher(),
        identityChecker: any ProcessIdentityChecking = SystemProcessIdentityChecker(),
        signaler: any ProcessSignaling = DarwinProcessSignaler(),
        fileManager: FileManager = .default
    ) {
        self.pidFileURL = pidFileURL
        self.executableURL = executableURL
        self.launcher = launcher
        self.identityChecker = identityChecker
        self.signaler = signaler
        self.fileManager = fileManager
    }

    public func start(arguments: [String]) throws {
        if activeProcess != nil {
            try restart(arguments: arguments)
            return
        }

        cleanupStaleProcess()
        try installReplacement(arguments: arguments, replacing: nil)
    }

    public func restart(arguments: [String]) throws {
        if activeProcess?.isRunning == true, activeArguments == arguments {
            return
        }

        try installReplacement(arguments: arguments, replacing: activeProcess)
    }

    public func stop() {
        if let activeProcess {
            activeProcess.terminate()
        } else {
            cleanupStaleProcess()
        }

        activeProcess = nil
        activePID = nil
        activeArguments = []
        try? fileManager.removeItem(at: pidFileURL)
    }

    public func cleanupStaleProcess() {
        defer {
            try? fileManager.removeItem(at: pidFileURL)
        }

        guard let storedIdentity = storedIdentity(),
              storedIdentity.pid > 0,
              storedIdentity.executablePath == executableURL.path,
              identityChecker.identity(forPID: storedIdentity.pid) == storedIdentity
        else {
            return
        }

        _ = signaler.terminate(pid: storedIdentity.pid)
    }

    private func installReplacement(
        arguments: [String],
        replacing previousProcess: (any ManagedAssertionProcess)?
    ) throws {
        let replacement = try launcher.launch(executableURL: executableURL, arguments: arguments)
        guard replacement.isRunning else {
            replacement.terminate()
            throw SessionAssertionControllerError.processDidNotStart
        }

        guard let replacementIdentity = identityChecker.identity(
            forPID: replacement.processIdentifier
        ), replacementIdentity.executablePath == executableURL.path else {
            replacement.terminate()
            throw SessionAssertionControllerError.processIdentityUnavailable
        }

        do {
            try persist(identity: replacementIdentity)
        } catch {
            replacement.terminate()
            throw error
        }

        activeProcess = replacement
        activePID = replacement.processIdentifier
        activeArguments = arguments
        previousProcess?.terminate()
    }

    private func storedIdentity() -> AssertionProcessIdentity? {
        guard let rawRecord = try? String(contentsOf: pidFileURL, encoding: .utf8) else {
            return nil
        }
        let fields = rawRecord.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3,
              let pid = Int32(fields[0]),
              let startTimeSeconds = UInt64(fields[1]),
              let startTimeMicroseconds = UInt64(fields[2])
        else {
            return nil
        }
        return AssertionProcessIdentity(
            pid: pid,
            executablePath: executableURL.path,
            startTimeSeconds: startTimeSeconds,
            startTimeMicroseconds: startTimeMicroseconds
        )
    }

    private func persist(identity: AssertionProcessIdentity) throws {
        try fileManager.createDirectory(
            at: pidFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let record = [
            "\(identity.pid)",
            "\(identity.startTimeSeconds)",
            "\(identity.startTimeMicroseconds)"
        ].joined(separator: " ")
        try record.write(to: pidFileURL, atomically: true, encoding: .utf8)
    }
}
