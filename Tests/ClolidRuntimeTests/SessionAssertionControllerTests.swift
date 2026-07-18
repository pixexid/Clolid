import ClolidCore
import Foundation
import XCTest
@testable import ClolidRuntime

final class SessionAssertionControllerTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var pidFileURL: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClolidRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        pidFileURL = temporaryDirectory.appendingPathComponent("caffeinate.pid")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testStartUsesRequestedArgumentsAndPersistsOwnedPID() throws {
        let events = EventLog()
        let launcher = FakeLauncher(processIDs: [101], events: events)
        let controller = makeController(launcher: launcher)

        try controller.start(arguments: SessionMode.agentDisplay.policy.caffeinateArguments)

        XCTAssertEqual(controller.activePID, 101)
        XCTAssertEqual(controller.activeArguments, ["-d", "-i", "-s"])
        XCTAssertEqual(try String(contentsOf: pidFileURL, encoding: .utf8), "101 1010 101")
        XCTAssertEqual(events.values, ["launch 101 -d -i -s"])
    }

    func testRestartStartsReplacementBeforeStoppingPreviousProcess() throws {
        let events = EventLog()
        let launcher = FakeLauncher(processIDs: [101, 202], events: events)
        let controller = makeController(launcher: launcher)

        try controller.start(arguments: SessionMode.standard.policy.caffeinateArguments)
        try controller.restart(arguments: SessionMode.agentDisplay.policy.caffeinateArguments)

        XCTAssertEqual(controller.activePID, 202)
        XCTAssertEqual(controller.activeArguments, ["-d", "-i", "-s"])
        XCTAssertEqual(
            events.values,
            ["launch 101 -i -s", "launch 202 -d -i -s", "terminate 101"]
        )
    }

    func testFailedRestartLeavesExistingAssertionRunning() throws {
        let events = EventLog()
        let launcher = FakeLauncher(processIDs: [101], events: events, failAtLaunch: 2)
        let controller = makeController(launcher: launcher)

        try controller.start(arguments: SessionMode.standard.policy.caffeinateArguments)
        XCTAssertThrowsError(
            try controller.restart(arguments: SessionMode.agentDisplay.policy.caffeinateArguments)
        )

        XCTAssertEqual(controller.activePID, 101)
        XCTAssertEqual(controller.activeArguments, ["-i", "-s"])
        XCTAssertEqual(events.values, ["launch 101 -i -s", "launch failed"])
    }

    func testStopTerminatesOnlyActiveOwnedProcessAndRemovesPIDFile() throws {
        let events = EventLog()
        let launcher = FakeLauncher(processIDs: [101], events: events)
        let signaler = FakeSignaler()
        let controller = makeController(launcher: launcher, signaler: signaler)

        try controller.start(arguments: SessionMode.standard.policy.caffeinateArguments)
        controller.stop()

        XCTAssertEqual(events.values, ["launch 101 -i -s", "terminate 101"])
        XCTAssertTrue(signaler.terminatedPIDs.isEmpty)
        XCTAssertNil(controller.activePID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFileURL.path))
    }

    func testStopIsIdempotent() throws {
        let events = EventLog()
        let launcher = FakeLauncher(processIDs: [101], events: events)
        let controller = makeController(launcher: launcher)

        try controller.start(arguments: SessionMode.standard.policy.caffeinateArguments)
        controller.stop()
        controller.stop()

        XCTAssertEqual(events.values, ["launch 101 -i -s", "terminate 101"])
    }

    func testCleanupSignalsStalePIDOnlyWhenItStillBelongsToCaffeinate() throws {
        try writeIdentityRecord(fakeIdentity(pid: 303))
        let signaler = FakeSignaler()
        let controller = makeController(
            launcher: FakeLauncher(processIDs: [], events: EventLog()),
            identityChecker: FakeIdentityChecker(identities: [303: fakeIdentity(pid: 303)]),
            signaler: signaler
        )

        controller.cleanupStaleProcess()

        XCTAssertEqual(signaler.terminatedPIDs, [303])
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFileURL.path))
    }

    func testCleanupDoesNotSignalReusedPIDForAnotherExecutable() throws {
        try writeIdentityRecord(fakeIdentity(pid: 404))
        let signaler = FakeSignaler()
        let controller = makeController(
            launcher: FakeLauncher(processIDs: [], events: EventLog()),
            identityChecker: FakeIdentityChecker(
                identities: [
                    404: fakeIdentity(pid: 404, path: "/Applications/Other.app/Other")
                ]
            ),
            signaler: signaler
        )

        controller.cleanupStaleProcess()

        XCTAssertTrue(signaler.terminatedPIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFileURL.path))
    }

    func testCleanupRejectsTruncatedProcessPath() throws {
        try writeIdentityRecord(fakeIdentity(pid: 405))
        let signaler = FakeSignaler()
        let controller = makeController(
            launcher: FakeLauncher(processIDs: [], events: EventLog()),
            identityChecker: FakeIdentityChecker(
                identities: [405: fakeIdentity(pid: 405, path: "/usr/bin/caffein")]
            ),
            signaler: signaler
        )

        controller.cleanupStaleProcess()

        XCTAssertTrue(signaler.terminatedPIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFileURL.path))
    }

    func testCleanupRejectsReusedPIDForAnotherCaffeinateStartIdentity() throws {
        try writeIdentityRecord(fakeIdentity(pid: 406))
        let signaler = FakeSignaler()
        let controller = makeController(
            launcher: FakeLauncher(processIDs: [], events: EventLog()),
            identityChecker: FakeIdentityChecker(
                identities: [406: fakeIdentity(pid: 406, startTimeSeconds: 9_999)]
            ),
            signaler: signaler
        )

        controller.cleanupStaleProcess()

        XCTAssertTrue(signaler.terminatedPIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFileURL.path))
    }

    func testCleanupRemovesMalformedOrNonPositivePIDWithoutSignaling() throws {
        let signaler = FakeSignaler()
        let controller = makeController(
            launcher: FakeLauncher(processIDs: [], events: EventLog()),
            signaler: signaler
        )

        for value in ["not-a-pid", "303", "0 0 0", "-1 1 1"] {
            try value.write(to: pidFileURL, atomically: true, encoding: .utf8)
            controller.cleanupStaleProcess()
            XCTAssertFalse(FileManager.default.fileExists(atPath: pidFileURL.path))
        }

        XCTAssertTrue(signaler.terminatedPIDs.isEmpty)
    }

    func testPIDPersistenceFailureTerminatesReplacement() throws {
        let blockedParentURL = temporaryDirectory.appendingPathComponent("not-a-directory")
        try "blocked".write(to: blockedParentURL, atomically: true, encoding: .utf8)
        let invalidPIDFileURL = blockedParentURL.appendingPathComponent("caffeinate.pid")
        let events = EventLog()
        let launcher = FakeLauncher(processIDs: [101], events: events)
        let controller = makeController(launcher: launcher, pidFileURL: invalidPIDFileURL)

        XCTAssertThrowsError(
            try controller.start(arguments: SessionMode.standard.policy.caffeinateArguments)
        )

        XCTAssertEqual(events.values, ["launch 101 -i -s", "terminate 101"])
        XCTAssertNil(controller.activePID)
    }

    func testIdentityFailureTerminatesReplacementWithoutPublishingOwnership() {
        let events = EventLog()
        let launcher = FakeLauncher(processIDs: [101], events: events)
        let controller = makeController(
            launcher: launcher,
            identityChecker: FakeIdentityChecker(defaultToCaffeinate: false)
        )

        XCTAssertThrowsError(
            try controller.start(arguments: SessionMode.standard.policy.caffeinateArguments)
        )

        XCTAssertEqual(events.values, ["launch 101 -i -s", "terminate 101"])
        XCTAssertNil(controller.activePID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFileURL.path))
    }

    private func writeIdentityRecord(_ identity: AssertionProcessIdentity) throws {
        let record = [
            "\(identity.pid)",
            "\(identity.startTimeSeconds)",
            "\(identity.startTimeMicroseconds)"
        ].joined(separator: " ")
        try record.write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private func makeController(
        launcher: FakeLauncher,
        identityChecker: FakeIdentityChecker = FakeIdentityChecker(),
        signaler: FakeSignaler = FakeSignaler(),
        pidFileURL: URL? = nil
    ) -> SessionAssertionController {
        SessionAssertionController(
            pidFileURL: pidFileURL ?? self.pidFileURL,
            launcher: launcher,
            identityChecker: identityChecker,
            signaler: signaler
        )
    }
}

private final class EventLog {
    var values: [String] = []
}

private final class FakeManagedProcess: ManagedAssertionProcess {
    let processIdentifier: Int32
    private(set) var isRunning = true
    private let events: EventLog

    init(processIdentifier: Int32, events: EventLog) {
        self.processIdentifier = processIdentifier
        self.events = events
    }

    func terminate() {
        isRunning = false
        events.values.append("terminate \(processIdentifier)")
    }
}

private enum FakeLauncherError: Error {
    case failed
}

private final class FakeLauncher: AssertionProcessLaunching {
    private let processIDs: [Int32]
    private let events: EventLog
    private let failAtLaunch: Int?
    private var launchCount = 0

    init(processIDs: [Int32], events: EventLog, failAtLaunch: Int? = nil) {
        self.processIDs = processIDs
        self.events = events
        self.failAtLaunch = failAtLaunch
    }

    func launch(executableURL: URL, arguments: [String]) throws -> any ManagedAssertionProcess {
        launchCount += 1
        if launchCount == failAtLaunch {
            events.values.append("launch failed")
            throw FakeLauncherError.failed
        }

        let processID = processIDs[launchCount - 1]
        events.values.append("launch \(processID) \(arguments.joined(separator: " "))")
        return FakeManagedProcess(processIdentifier: processID, events: events)
    }
}

private struct FakeIdentityChecker: ProcessIdentityChecking {
    let identities: [Int32: AssertionProcessIdentity]
    let defaultToCaffeinate: Bool

    init(
        identities: [Int32: AssertionProcessIdentity] = [:],
        defaultToCaffeinate: Bool = true
    ) {
        self.identities = identities
        self.defaultToCaffeinate = defaultToCaffeinate
    }

    func identity(forPID pid: Int32) -> AssertionProcessIdentity? {
        if let identity = identities[pid] {
            return identity
        }
        return defaultToCaffeinate ? fakeIdentity(pid: pid) : nil
    }
}

private func fakeIdentity(
    pid: Int32,
    path: String = "/usr/bin/caffeinate",
    startTimeSeconds: UInt64? = nil
) -> AssertionProcessIdentity {
    AssertionProcessIdentity(
        pid: pid,
        executablePath: path,
        startTimeSeconds: startTimeSeconds ?? UInt64(pid) * 10,
        startTimeMicroseconds: UInt64(pid)
    )
}

private final class FakeSignaler: ProcessSignaling {
    private(set) var terminatedPIDs: [Int32] = []

    @discardableResult
    func terminate(pid: Int32) -> Bool {
        terminatedPIDs.append(pid)
        return true
    }
}
