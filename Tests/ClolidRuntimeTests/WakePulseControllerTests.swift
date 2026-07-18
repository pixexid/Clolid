import Foundation
import XCTest
@testable import ClolidRuntime

final class WakePulseControllerTests: XCTestCase {
    func testIssueUsesUserActivityAssertionWithRoundedUpTimeout() throws {
        let events = WakeEventLog()
        let launcher = WakeFakeLauncher(processIDs: [101], events: events)
        let controller = WakePulseController(launcher: launcher)

        try controller.issue(duration: 5.1)

        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(events.values, ["launch 101 -u -t 6"])
    }

    func testReplacementStartsBeforePreviousPulseStops() throws {
        let events = WakeEventLog()
        let launcher = WakeFakeLauncher(processIDs: [101, 202], events: events)
        let controller = WakePulseController(launcher: launcher)

        try controller.issue(duration: 5)
        try controller.issue(duration: 3)

        XCTAssertEqual(
            events.values,
            ["launch 101 -u -t 5", "launch 202 -u -t 3", "terminate 101"]
        )
    }

    func testFailedReplacementPreservesPreviousPulse() throws {
        let events = WakeEventLog()
        let launcher = WakeFakeLauncher(processIDs: [101], events: events, failAtLaunch: 2)
        let controller = WakePulseController(launcher: launcher)

        try controller.issue(duration: 5)
        XCTAssertThrowsError(try controller.issue(duration: 5))

        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(events.values, ["launch 101 -u -t 5", "launch failed"])
    }

    func testStopTerminatesOnlyTheOwnedPulse() throws {
        let events = WakeEventLog()
        let launcher = WakeFakeLauncher(processIDs: [101], events: events)
        let controller = WakePulseController(launcher: launcher)

        try controller.issue(duration: 5)
        controller.stop()
        controller.stop()

        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(events.values, ["launch 101 -u -t 5", "terminate 101"])
    }

    func testPrepareRecoveryInputRequestsPostingAccess() {
        let events = WakeEventLog()
        let launcher = WakeFakeLauncher(processIDs: [], events: events)
        let inputPoster = WakeFakeRecoveryInputPoster(events: events)
        let controller = WakePulseController(
            launcher: launcher,
            recoveryInputPoster: inputPoster
        )

        XCTAssertTrue(controller.prepareRecoveryInputAccess())
        XCTAssertEqual(events.values, ["request input access"])
    }

    func testRecoveryPulseStartsAssertionThenPostsInputNudge() throws {
        let events = WakeEventLog()
        let launcher = WakeFakeLauncher(processIDs: [101], events: events)
        let inputPoster = WakeFakeRecoveryInputPoster(events: events)
        let controller = WakePulseController(
            launcher: launcher,
            recoveryInputPoster: inputPoster
        )

        try controller.issueRecovery(duration: 5)

        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(events.values, ["launch 101 -u -t 5", "post input nudge"])
    }

    func testFailedRecoveryInputLeavesWakeAssertionRunning() {
        let events = WakeEventLog()
        let launcher = WakeFakeLauncher(processIDs: [101], events: events)
        let inputPoster = WakeFakeRecoveryInputPoster(events: events, postFails: true)
        let controller = WakePulseController(
            launcher: launcher,
            recoveryInputPoster: inputPoster
        )

        XCTAssertThrowsError(try controller.issueRecovery(duration: 5))

        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(events.values, ["launch 101 -u -t 5", "post input failed"])
    }
}

private final class WakeEventLog {
    var values: [String] = []
}

private final class WakeFakeProcess: ManagedAssertionProcess {
    let processIdentifier: Int32
    private(set) var isRunning = true
    private let events: WakeEventLog

    init(processIdentifier: Int32, events: WakeEventLog) {
        self.processIdentifier = processIdentifier
        self.events = events
    }

    func terminate() {
        isRunning = false
        events.values.append("terminate \(processIdentifier)")
    }
}

private enum WakeFakeLauncherError: Error {
    case failed
}

private enum WakeFakeRecoveryInputError: Error {
    case failed
}

private final class WakeFakeRecoveryInputPoster: RecoveryInputPosting {
    private let events: WakeEventLog
    private let postFails: Bool

    init(events: WakeEventLog, postFails: Bool = false) {
        self.events = events
        self.postFails = postFails
    }

    func requestAccess() -> Bool {
        events.values.append("request input access")
        return true
    }

    func postNudge() throws {
        if postFails {
            events.values.append("post input failed")
            throw WakeFakeRecoveryInputError.failed
        }
        events.values.append("post input nudge")
    }
}

private final class WakeFakeLauncher: AssertionProcessLaunching {
    private let processIDs: [Int32]
    private let events: WakeEventLog
    private let failAtLaunch: Int?
    private var launchCount = 0

    init(processIDs: [Int32], events: WakeEventLog, failAtLaunch: Int? = nil) {
        self.processIDs = processIDs
        self.events = events
        self.failAtLaunch = failAtLaunch
    }

    func launch(executableURL: URL, arguments: [String]) throws -> any ManagedAssertionProcess {
        launchCount += 1
        if launchCount == failAtLaunch {
            events.values.append("launch failed")
            throw WakeFakeLauncherError.failed
        }

        let processID = processIDs[launchCount - 1]
        events.values.append("launch \(processID) \(arguments.joined(separator: " "))")
        return WakeFakeProcess(processIdentifier: processID, events: events)
    }
}
