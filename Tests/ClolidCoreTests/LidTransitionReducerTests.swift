import XCTest
@testable import ClolidCore

final class LidTransitionReducerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let reducer = LidTransitionReducer(
        configuration: DisplayTransitionConfiguration(
            settleDelay: 0.5,
            sampleInterval: 0.5,
            requiredStableSamples: 3,
            missingDisplayWarningDelay: 5,
            wakePulseDuration: 5
        )
    )

    func testAgentModeNeverSleepsDisplaysDuringTransientDisconnect() {
        var state = runningState(mode: .agentDisplay, topology: topology(externalDisplay: true))
        let preferences = agentPreferences()

        let closeEffects = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: false), at: start),
            preferences: preferences
        )
        let firstMissingSample = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: false, offset: 0.5)),
            preferences: preferences
        )
        let secondMissingSample = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: false, offset: 1)),
            preferences: preferences
        )
        let thirdMissingSample = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: false, offset: 1.5)),
            preferences: preferences
        )

        XCTAssertEqual(closeEffects.filter(\.isWakePulse).count, 0)
        XCTAssertFalse((closeEffects + firstMissingSample + secondMissingSample + thirdMissingSample).contains(.sleepAllDisplays))
    }

    func testAgentModeNeverSleepsWhenNoExternalDisplayIsEverPresent() {
        var state = runningState(mode: .agentDisplay, topology: topology(externalDisplay: false))
        let preferences = agentPreferences()

        _ = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: false), at: start),
            preferences: preferences
        )
        let effects = (1...3).flatMap { sample in
            reducer.reduce(
                state: &state,
                event: .topologyChanged(topology(externalDisplay: false, offset: Double(sample) * 0.5)),
                preferences: preferences
            )
        }

        XCTAssertFalse(effects.contains(.sleepAllDisplays))
        XCTAssertTrue(closeContext(from: state).automaticSleepEvaluated)
        XCTAssertFalse(closeContext(from: state).automaticSleepIssued)
    }

    func testAgentModeIssuesOneWakePulseWhenDisplayReconnects() {
        var state = runningState(mode: .agentDisplay, topology: topology(externalDisplay: false))
        let preferences = agentPreferences()

        _ = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: false), at: start),
            preferences: preferences
        )
        _ = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: false, offset: 0.5)),
            preferences: preferences
        )
        _ = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: false, offset: 1)),
            preferences: preferences
        )
        let reconnectEffects = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: true, offset: 2)),
            preferences: preferences
        )
        let secondStableSample = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: true, offset: 2.5)),
            preferences: preferences
        )
        let thirdStableSample = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: true, offset: 3)),
            preferences: preferences
        )

        let effects = reconnectEffects + secondStableSample + thirdStableSample
        XCTAssertEqual(effects.filter(\.isWakePulse).count, 1)
        XCTAssertFalse(effects.contains(.sleepAllDisplays))
        guard case .closed = state.phase else {
            return XCTFail("Expected the reconnected topology to become stable")
        }
    }

    func testAgentModeWarnsOnceWhenDisplayRemainsMissing() {
        var state = runningState(mode: .agentDisplay, topology: topology(externalDisplay: false))
        let preferences = agentPreferences()

        _ = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: false), at: start),
            preferences: preferences
        )
        let firstWarning = reducer.reduce(
            state: &state,
            event: .settleTimerFired(at: start.addingTimeInterval(5)),
            preferences: preferences
        )
        let duplicateWarning = reducer.reduce(
            state: &state,
            event: .settleTimerFired(at: start.addingTimeInterval(10)),
            preferences: preferences
        )

        XCTAssertEqual(firstWarning.filter(\.isMissingDisplayWarning).count, 1)
        XCTAssertEqual(duplicateWarning.filter(\.isMissingDisplayWarning).count, 0)
    }

    func testStandardModeSuppressesSleepForWholeClosureWhenDisplayWasPresentBeforeClose() {
        var state = runningState(mode: .standard, topology: topology(externalDisplay: true))
        let preferences = standardPreferences()

        _ = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: false), at: start),
            preferences: preferences
        )
        let effects = (1...3).flatMap { sample in
            reducer.reduce(
                state: &state,
                event: .topologyChanged(topology(externalDisplay: false, offset: Double(sample) * 0.5)),
                preferences: preferences
            )
        }

        XCTAssertFalse(effects.contains(.sleepAllDisplays))
        XCTAssertTrue(closeContext(from: state).automaticSleepEvaluated)
        XCTAssertFalse(closeContext(from: state).automaticSleepIssued)
    }

    func testStandardModeSleepsOnceAfterStableNoDisplaySamples() {
        var state = runningState(mode: .standard, topology: topology(externalDisplay: false))
        let preferences = standardPreferences()

        _ = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: false), at: start),
            preferences: preferences
        )
        let secondSample = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: false, offset: 0.5)),
            preferences: preferences
        )
        let thirdSample = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: false, offset: 1)),
            preferences: preferences
        )
        let laterSample = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: false, offset: 2)),
            preferences: preferences
        )

        XCTAssertFalse(secondSample.contains(.sleepAllDisplays))
        XCTAssertEqual((thirdSample + laterSample).filter { $0 == .sleepAllDisplays }.count, 1)
    }

    func testStandardModeDoesNotTreatBurstCallbacksAsStableSamples() {
        var state = runningState(mode: .standard, topology: topology(externalDisplay: false))
        let preferences = standardPreferences()

        _ = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: false), at: start),
            preferences: preferences
        )
        let burstEffects = [0.1, 0.2, 0.3].flatMap { offset in
            reducer.reduce(
                state: &state,
                event: .topologyChanged(topology(externalDisplay: false, offset: offset)),
                preferences: preferences
            )
        }

        XCTAssertFalse(burstEffects.contains(.sleepAllDisplays))
        XCTAssertEqual(closeContext(from: state).consecutiveStableSamples, 1)

        _ = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: false, offset: 0.5)),
            preferences: preferences
        )
        let stableEffects = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: false, offset: 1)),
            preferences: preferences
        )

        XCTAssertEqual(stableEffects.filter { $0 == .sleepAllDisplays }.count, 1)
    }

    func testStaleTopologySnapshotCannotOverwriteNewerDisplayState() {
        var state = runningState(mode: .agentDisplay, topology: topology(externalDisplay: false))
        let preferences = agentPreferences()

        _ = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: false), at: start),
            preferences: preferences
        )
        _ = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: true, offset: 2)),
            preferences: preferences
        )
        let staleEffects = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: false, offset: 1)),
            preferences: preferences
        )
        let warningEffects = reducer.reduce(
            state: &state,
            event: .settleTimerFired(at: start.addingTimeInterval(5)),
            preferences: preferences
        )

        XCTAssertTrue(staleEffects.isEmpty)
        XCTAssertTrue(closeContext(from: state).latestTopology.hasExternalOnlineDisplay)
        XCTAssertFalse(warningEffects.contains(where: \.isMissingDisplayWarning))
    }

    func testStandardModeDoesNotSleepIfDisplayAppearsDuringSettling() {
        var state = runningState(mode: .standard, topology: topology(externalDisplay: false))
        let preferences = standardPreferences()

        _ = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: false), at: start),
            preferences: preferences
        )
        _ = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: true, offset: 0.5)),
            preferences: preferences
        )
        let effects = (2...4).flatMap { sample in
            reducer.reduce(
                state: &state,
                event: .topologyChanged(topology(externalDisplay: false, offset: Double(sample) * 0.5)),
                preferences: preferences
            )
        }

        XCTAssertFalse(effects.contains(.sleepAllDisplays))
    }

    func testOpeningLidResetsCloseContext() {
        var state = runningState(mode: .agentDisplay, topology: topology(externalDisplay: true))
        let preferences = agentPreferences()

        _ = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: true), at: start),
            preferences: preferences
        )
        let effects = reducer.reduce(
            state: &state,
            event: .lidOpened(topology: topology(externalDisplay: true, offset: 1), at: start.addingTimeInterval(1)),
            preferences: preferences
        )

        XCTAssertEqual(state.phase, .open)
        XCTAssertEqual(effects, [.publishReadiness])
    }

    func testDuplicateCloseDoesNotRepeatWakePulse() {
        var state = runningState(mode: .agentDisplay, topology: topology(externalDisplay: true))
        let preferences = agentPreferences()

        let first = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: true), at: start),
            preferences: preferences
        )
        let duplicate = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: true), at: start.addingTimeInterval(0.1)),
            preferences: preferences
        )

        XCTAssertEqual(first.filter(\.isWakePulse).count, 1)
        XCTAssertTrue(duplicate.isEmpty)
    }

    func testAgentModeRenewsWakePulseAfterDummyAndPhysicalDisplaysSettle() {
        let closeTopology = topologyWithDummyAndPhysicalDisplay(
            physicalDisplayActive: true
        )
        var state = runningState(mode: .agentDisplay, topology: closeTopology)
        let preferences = agentPreferences()

        let closeEffects = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: closeTopology, at: start),
            preferences: preferences
        )
        let secondSampleEffects = reducer.reduce(
            state: &state,
            event: .topologyChanged(
                topologyWithDummyAndPhysicalDisplay(
                    physicalDisplayActive: false,
                    offset: 0.5
                )
            ),
            preferences: preferences
        )
        let stableEffects = reducer.reduce(
            state: &state,
            event: .topologyChanged(
                topologyWithDummyAndPhysicalDisplay(
                    physicalDisplayActive: false,
                    offset: 1
                )
            ),
            preferences: preferences
        )
        let laterEffects = reducer.reduce(
            state: &state,
            event: .topologyChanged(
                topologyWithDummyAndPhysicalDisplay(
                    physicalDisplayActive: false,
                    offset: 1.5
                )
            ),
            preferences: preferences
        )

        XCTAssertEqual(closeEffects.filter(\.isWakePulse).count, 1)
        XCTAssertEqual(secondSampleEffects.filter(\.isWakePulse).count, 0)
        XCTAssertEqual(stableEffects.filter(\.isWakePulse).count, 1)
        XCTAssertEqual(laterEffects.filter(\.isWakePulse).count, 0)
        XCTAssertFalse(
            (closeEffects + secondSampleEffects + stableEffects + laterEffects)
                .contains(.sleepAllDisplays)
        )
        XCTAssertTrue(closeContext(from: state).postSettleWakePulseIssued)
    }

    func testFailedPostSettleWakePulseCanRetry() {
        let closeTopology = topology(externalDisplay: true)
        var state = runningState(mode: .agentDisplay, topology: closeTopology)
        let preferences = agentPreferences()

        _ = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: closeTopology, at: start),
            preferences: preferences
        )
        _ = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: true, offset: 0.5)),
            preferences: preferences
        )
        let postSettleEffects = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: true, offset: 1)),
            preferences: preferences
        )
        _ = reducer.reduce(
            state: &state,
            event: .wakePulseFailed(at: start.addingTimeInterval(1.1)),
            preferences: preferences
        )
        let retryEffects = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: true, offset: 1.5)),
            preferences: preferences
        )

        XCTAssertEqual(postSettleEffects.filter(\.isWakePulse).count, 1)
        XCTAssertEqual(retryEffects.filter(\.isWakePulse).count, 1)
        XCTAssertTrue(closeContext(from: state).postSettleWakePulseIssued)
    }

    func testAgentModeIssuesOneRecoveryWakeWhenExternalDisplaysDropAfterSettling() {
        let closeTopology = topology(externalDisplay: true)
        var state = runningState(mode: .agentDisplay, topology: closeTopology)
        let preferences = agentPreferences()

        _ = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: closeTopology, at: start),
            preferences: preferences
        )
        _ = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: true, offset: 0.5)),
            preferences: preferences
        )
        _ = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: true, offset: 1)),
            preferences: preferences
        )
        let displayDropEffects = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: false, offset: 1.5)),
            preferences: preferences
        )
        let laterMissingEffects = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: false, offset: 2)),
            preferences: preferences
        )

        XCTAssertEqual(displayDropEffects.filter(\.isRecoveryWake).count, 1)
        XCTAssertTrue(displayDropEffects.contains(.refreshTopology(after: 0.5)))
        XCTAssertEqual(laterMissingEffects.filter(\.isRecoveryWake).count, 0)
        XCTAssertTrue(closeContext(from: state).recoveryWakeIssued)
    }

    func testACPowerLossRequestsStopOnlyWhenRequired() {
        var requiredState = runningState(mode: .agentDisplay, topology: topology(externalDisplay: true))
        var optionalState = requiredState

        let requiredEffects = reducer.reduce(
            state: &requiredState,
            event: .powerChanged(isOnAC: false, at: start),
            preferences: agentPreferences(requireACPower: true)
        )
        let optionalEffects = reducer.reduce(
            state: &optionalState,
            event: .powerChanged(isOnAC: false, at: start),
            preferences: agentPreferences(requireACPower: false)
        )

        XCTAssertTrue(requiredEffects.contains(.requestSessionStop(reason: "External power disconnected.")))
        XCTAssertFalse(optionalEffects.contains { effect in
            if case .requestSessionStop = effect {
                return true
            }
            return false
        })
    }

    func testModeChangePreservesCloseContextAndIssuesAtMostOneWakePulse() {
        var state = runningState(mode: .standard, topology: topology(externalDisplay: true))

        _ = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: true), at: start),
            preferences: standardPreferences()
        )
        let agentEffects = reducer.reduce(
            state: &state,
            event: .sessionModeChanged(mode: .agentDisplay, at: start.addingTimeInterval(1)),
            preferences: agentPreferences()
        )
        let duplicateEffects = reducer.reduce(
            state: &state,
            event: .sessionModeChanged(mode: .agentDisplay, at: start.addingTimeInterval(2)),
            preferences: agentPreferences()
        )

        XCTAssertEqual(state.sessionMode, .agentDisplay)
        XCTAssertEqual(agentEffects.filter(\.isWakePulse).count, 1)
        XCTAssertEqual(duplicateEffects.filter(\.isWakePulse).count, 0)
        XCTAssertEqual(closeContext(from: state).closedAt, start)
    }

    func testFailedWakePulseCanRetryOnLaterQualifyingTopologyEvent() {
        var state = runningState(mode: .agentDisplay, topology: topology(externalDisplay: true))
        let preferences = agentPreferences()

        let closeEffects = reducer.reduce(
            state: &state,
            event: .lidClosed(topology: topology(externalDisplay: true), at: start),
            preferences: preferences
        )
        _ = reducer.reduce(
            state: &state,
            event: .wakePulseFailed(at: start.addingTimeInterval(0.1)),
            preferences: preferences
        )
        let retryEffects = reducer.reduce(
            state: &state,
            event: .topologyChanged(topology(externalDisplay: true, offset: 0.5)),
            preferences: preferences
        )

        XCTAssertEqual(closeEffects.filter(\.isWakePulse).count, 1)
        XCTAssertEqual(retryEffects.filter(\.isWakePulse).count, 1)
        XCTAssertTrue(closeContext(from: state).wakePulseIssued)
    }

    private func runningState(mode: SessionMode, topology: DisplayTopology) -> LidTransitionState {
        LidTransitionState(
            sessionMode: mode,
            sessionRunning: true,
            phase: .open,
            latestTopology: topology,
            isOnACPower: true
        )
    }

    private func topology(externalDisplay: Bool, offset: TimeInterval = 0) -> DisplayTopology {
        var displays = [
            DisplayDescriptor(
                id: 1,
                name: "Built-in Display",
                isBuiltIn: true,
                isOnline: true,
                isActive: true,
                isMain: !externalDisplay,
                isMirrored: false,
                width: 1_728,
                height: 1_117,
                scale: 2
            )
        ]

        if externalDisplay {
            displays.append(
                DisplayDescriptor(
                    id: 2,
                    name: "Agent Display",
                    isBuiltIn: false,
                    isOnline: true,
                    isActive: true,
                    isMain: true,
                    isMirrored: false,
                    width: 1_920,
                    height: 1_080,
                    scale: 1
                )
            )
        }

        return DisplayTopology(observedAt: start.addingTimeInterval(offset), displays: displays)
    }

    private func topologyWithDummyAndPhysicalDisplay(
        physicalDisplayActive: Bool,
        offset: TimeInterval = 0
    ) -> DisplayTopology {
        DisplayTopology(
            observedAt: start.addingTimeInterval(offset),
            displays: [
                DisplayDescriptor(
                    id: 1,
                    name: "Built-in Display",
                    isBuiltIn: true,
                    isOnline: true,
                    isActive: true,
                    isMain: false,
                    isMirrored: false,
                    width: 1_728,
                    height: 1_117,
                    scale: 2
                ),
                DisplayDescriptor(
                    id: 2,
                    name: "Dummy Display",
                    isBuiltIn: false,
                    isOnline: true,
                    isActive: true,
                    isMain: !physicalDisplayActive,
                    isMirrored: false,
                    width: 3_840,
                    height: 2_160,
                    scale: 2
                ),
                DisplayDescriptor(
                    id: 3,
                    name: "Physical Display",
                    isBuiltIn: false,
                    isOnline: true,
                    isActive: physicalDisplayActive,
                    isMain: physicalDisplayActive,
                    isMirrored: false,
                    width: 1_920,
                    height: 1_280,
                    scale: 1
                )
            ]
        )
    }

    private func standardPreferences() -> LidTransitionPreferences {
        LidTransitionPreferences(
            automaticDisplaySleepEnabled: true,
            wakePulseEnabled: false,
            missingDisplayWarningEnabled: false,
            requireACPower: false
        )
    }

    private func agentPreferences(requireACPower: Bool = true) -> LidTransitionPreferences {
        LidTransitionPreferences(
            automaticDisplaySleepEnabled: true,
            wakePulseEnabled: true,
            missingDisplayWarningEnabled: true,
            requireACPower: requireACPower
        )
    }

    private func closeContext(from state: LidTransitionState) -> LidCloseContext {
        switch state.phase {
        case .settling(let context), .closed(let context):
            return context
        case .open:
            XCTFail("Expected a closed-lid context")
            return LidCloseContext(closedAt: start, preCloseTopology: topology(externalDisplay: false))
        }
    }
}

private extension LidRuntimeEffect {
    var isWakePulse: Bool {
        if case .issueWakePulse = self {
            return true
        }
        return false
    }

    var isRecoveryWake: Bool {
        if case .issueRecoveryWake = self {
            return true
        }
        return false
    }

    var isMissingDisplayWarning: Bool {
        if case .notifyOnce(let code, _, _) = self {
            return code == "agent-display-missing"
        }
        return false
    }
}
