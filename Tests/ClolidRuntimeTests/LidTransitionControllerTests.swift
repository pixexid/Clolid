import ClolidCore
import Foundation
import XCTest
@testable import ClolidRuntime

final class LidTransitionControllerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testStartWhileAlreadyClosedSeedsCloseTransitionAndWakePulse() {
        let provider = FakeTopologyProvider(results: [.success(topology(externalActive: true))])
        let wakePulse = FakeWakePulseController()
        let delegate = FakeTransitionDelegate()
        let controller = makeController(provider: provider, wakePulse: wakePulse)
        controller.delegate = delegate

        let started = controller.start(
            mode: .agentDisplay,
            lidClosed: true,
            isOnACPower: true,
            preferences: agentPreferences(),
            at: start
        )

        XCTAssertTrue(started)
        XCTAssertTrue(controller.state.sessionRunning)
        XCTAssertEqual(wakePulse.durations, [5])
        guard case .settling = controller.state.phase else {
            return XCTFail("Expected a close transition to be settling")
        }
    }

    func testCaptureFailureCannotBecomeAnEmptyCloseSample() {
        let provider = FakeTopologyProvider(
            results: [
                .success(topology(externalActive: true)),
                .failure(FakeTopologyError.failed)
            ]
        )
        let delegate = FakeTransitionDelegate()
        let controller = makeController(provider: provider)
        controller.delegate = delegate

        XCTAssertTrue(
            controller.start(
                mode: .standard,
                lidClosed: false,
                isOnACPower: true,
                preferences: standardPreferences(),
                at: start
            )
        )
        let handled = controller.lidChanged(
            closed: true,
            preferences: standardPreferences(),
            at: start.addingTimeInterval(1)
        )

        XCTAssertFalse(handled)
        XCTAssertFalse(controller.lastCaptureSucceeded)
        XCTAssertEqual(controller.state.latestTopology?.hasExternalOnlineDisplay, true)
        XCTAssertEqual(controller.state.phase, .open)
        XCTAssertFalse(delegate.effects.contains(.sleepAllDisplays))
        XCTAssertEqual(delegate.captureFailures.count, 1)
    }

    func testScheduledRefreshFromStoppedSessionIsIgnoredEvenIfCallbackFires() {
        let provider = FakeTopologyProvider(results: [.success(topology(externalActive: false))])
        let scheduler = FakeTransitionScheduler()
        let controller = makeController(provider: provider, scheduler: scheduler)

        XCTAssertTrue(
            controller.start(
                mode: .agentDisplay,
                lidClosed: true,
                isOnACPower: true,
                preferences: agentPreferences(),
                at: start
            )
        )
        XCTAssertFalse(scheduler.tasks.isEmpty)

        controller.stop(at: start.addingTimeInterval(1))
        scheduler.fireAllIgnoringCancellation()

        XCTAssertFalse(controller.state.sessionRunning)
        XCTAssertEqual(provider.captureCount, 1)
    }

    func testAgentReconnectIssuesOnlyOneWakePulse() {
        let provider = FakeTopologyProvider(
            results: [
                .success(topology(externalActive: false, offset: 0)),
                .success(topology(externalActive: true, offset: 1)),
                .success(topology(externalActive: true, offset: 2))
            ]
        )
        let wakePulse = FakeWakePulseController()
        let controller = makeController(provider: provider, wakePulse: wakePulse)

        XCTAssertTrue(
            controller.start(
                mode: .agentDisplay,
                lidClosed: true,
                isOnACPower: true,
                preferences: agentPreferences(),
                at: start
            )
        )
        controller.refreshTopology(
            preferences: agentPreferences(),
            at: start.addingTimeInterval(1)
        )
        controller.refreshTopology(
            preferences: agentPreferences(),
            at: start.addingTimeInterval(2)
        )

        XCTAssertEqual(wakePulse.durations, [5])
    }

    func testModeUpdateChangesPolicyWithoutResettingCloseContext() {
        let provider = FakeTopologyProvider(results: [.success(topology(externalActive: true))])
        let wakePulse = FakeWakePulseController()
        let controller = makeController(provider: provider, wakePulse: wakePulse)

        XCTAssertTrue(
            controller.start(
                mode: .standard,
                lidClosed: true,
                isOnACPower: true,
                preferences: standardPreferences(),
                at: start
            )
        )
        controller.updateMode(
            .agentDisplay,
            preferences: agentPreferences(),
            at: start.addingTimeInterval(1)
        )

        XCTAssertEqual(controller.state.sessionMode, .agentDisplay)
        XCTAssertEqual(wakePulse.durations, [5])
        guard case .settling(let context) = controller.state.phase else {
            return XCTFail("Expected the existing close transition to remain active")
        }
        XCTAssertEqual(context.closedAt, start)
    }

    func testFailedWakePulseRetriesOnLaterTopologySample() {
        let provider = FakeTopologyProvider(
            results: [
                .success(topology(externalActive: true, offset: 0)),
                .success(topology(externalActive: true, offset: 1))
            ]
        )
        let wakePulse = FakeWakePulseController(failuresRemaining: 1)
        let delegate = FakeTransitionDelegate()
        let controller = makeController(provider: provider, wakePulse: wakePulse)
        controller.delegate = delegate

        XCTAssertTrue(
            controller.start(
                mode: .agentDisplay,
                lidClosed: true,
                isOnACPower: true,
                preferences: agentPreferences(),
                at: start
            )
        )
        controller.refreshTopology(
            preferences: agentPreferences(),
            at: start.addingTimeInterval(1)
        )

        XCTAssertEqual(wakePulse.durations, [5, 5])
        XCTAssertTrue(wakePulse.isRunning)
        XCTAssertEqual(delegate.runtimeFailures.count, 1)
    }

    private func makeController(
        provider: FakeTopologyProvider,
        wakePulse: FakeWakePulseController = FakeWakePulseController(),
        scheduler: FakeTransitionScheduler = FakeTransitionScheduler()
    ) -> LidTransitionController {
        LidTransitionController(
            reducer: LidTransitionReducer(
                configuration: DisplayTransitionConfiguration(
                    settleDelay: 0.5,
                    sampleInterval: 0.5,
                    requiredStableSamples: 3,
                    missingDisplayWarningDelay: 5,
                    wakePulseDuration: 5
                )
            ),
            topologyProvider: provider,
            wakePulseController: wakePulse,
            scheduler: scheduler
        )
    }

    private func topology(externalActive: Bool, offset: TimeInterval = 0) -> DisplayTopology {
        var displays = [
            DisplayDescriptor(
                id: 1,
                isBuiltIn: true,
                isOnline: true,
                isActive: true,
                isMain: !externalActive,
                isMirrored: false,
                width: 1_728,
                height: 1_117
            )
        ]
        if externalActive {
            displays.append(
                DisplayDescriptor(
                    id: 2,
                    isBuiltIn: false,
                    isOnline: true,
                    isActive: true,
                    isMain: true,
                    isMirrored: false,
                    width: 1_920,
                    height: 1_080
                )
            )
        }
        return DisplayTopology(observedAt: start.addingTimeInterval(offset), displays: displays)
    }

    private func standardPreferences() -> LidTransitionPreferences {
        LidTransitionPreferences(
            automaticDisplaySleepEnabled: true,
            wakePulseEnabled: false,
            missingDisplayWarningEnabled: false,
            requireACPower: false
        )
    }

    private func agentPreferences() -> LidTransitionPreferences {
        LidTransitionPreferences(
            automaticDisplaySleepEnabled: true,
            wakePulseEnabled: true,
            missingDisplayWarningEnabled: true,
            requireACPower: false
        )
    }
}

private enum FakeTopologyError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Topology capture failed."
    }
}

private final class FakeTopologyProvider: DisplayTopologyProviding {
    private var results: [Result<DisplayTopology, Error>]
    private(set) var captureCount = 0

    init(results: [Result<DisplayTopology, Error>]) {
        self.results = results
    }

    func snapshot(at observedAt: Date) throws -> DisplayTopology {
        captureCount += 1
        guard !results.isEmpty else {
            throw FakeTopologyError.failed
        }
        return try results.removeFirst().get()
    }
}

private final class FakeWakePulseController: WakePulseControlling {
    private(set) var durations: [TimeInterval] = []
    private(set) var isRunning = false
    private var failuresRemaining: Int

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
    }

    func issue(duration: TimeInterval) throws {
        durations.append(duration)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw FakeWakePulseError.failed
        }
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

private enum FakeWakePulseError: Error {
    case failed
}

private final class FakeScheduledTransition: ScheduledTransition {
    let action: () -> Void
    private(set) var isCancelled = false

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func cancel() {
        isCancelled = true
    }
}

private final class FakeTransitionScheduler: LidTransitionScheduling {
    private(set) var tasks: [FakeScheduledTransition] = []

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> any ScheduledTransition {
        let task = FakeScheduledTransition(action: action)
        tasks.append(task)
        return task
    }

    func fireAllIgnoringCancellation() {
        tasks.forEach { $0.action() }
    }
}

private final class FakeTransitionDelegate: LidTransitionControllerDelegate {
    private(set) var effects: [LidRuntimeEffect] = []
    private(set) var captureFailures: [String] = []
    private(set) var runtimeFailures: [String] = []

    func lidTransitionController(
        _ controller: LidTransitionController,
        didRequest effect: LidRuntimeEffect,
        state: LidTransitionState
    ) {
        effects.append(effect)
    }

    func lidTransitionController(
        _ controller: LidTransitionController,
        topologyCaptureDidFail message: String,
        state: LidTransitionState
    ) {
        captureFailures.append(message)
    }

    func lidTransitionController(
        _ controller: LidTransitionController,
        runtimeActionDidFail message: String,
        state: LidTransitionState
    ) {
        runtimeFailures.append(message)
    }
}
