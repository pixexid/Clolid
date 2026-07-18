import XCTest
@testable import ClolidCore

final class AgentReadinessEvaluatorTests: XCTestCase {
    private let evaluator = AgentReadinessEvaluator()

    func testStandardModeDoesNotApplyAgentReadinessRequirements() {
        let readiness = evaluator.evaluate(inputs(mode: .standard))

        XCTAssertEqual(readiness.severity, .ready)
        XCTAssertEqual(readiness.summary, "Standard mode")
        XCTAssertTrue(readiness.reasons.isEmpty)
    }

    func testHealthyAgentSessionIsReady() {
        let readiness = evaluator.evaluate(
            inputs(
                topology: topology(externalActive: true),
                keyboard: .present,
                pointingDevice: .present
            )
        )

        XCTAssertEqual(readiness.severity, .ready)
        XCTAssertEqual(readiness.summary, "Ready")
        XCTAssertTrue(readiness.reasons.isEmpty)
    }

    func testMissingTopologyAndAssertionAreBlocking() {
        let readiness = evaluator.evaluate(
            inputs(topology: nil, assertionRunning: false)
        )

        XCTAssertEqual(readiness.severity, .blocking)
        XCTAssertTrue(readiness.reasons.contains { $0.code == "topology-unavailable" })
        XCTAssertTrue(readiness.reasons.contains { $0.code == "assertion-missing" })
    }

    func testUnknownInputDevicesRemainAdvisory() {
        let readiness = evaluator.evaluate(
            inputs(
                topology: topology(externalActive: true),
                keyboard: .unknown(reason: "Keyboard metadata is unavailable."),
                pointingDevice: .unknown(reason: "Pointing-device metadata is unavailable.")
            )
        )

        XCTAssertEqual(readiness.severity, .advisory)
        XCTAssertEqual(readiness.summary, "Ready with advisories")
        XCTAssertTrue(readiness.reasons.contains { $0.code == "external-keyboard-unknown" })
        XCTAssertTrue(readiness.reasons.contains { $0.code == "external-pointing-device-unknown" })
    }

    func testMissingInputDevicesAreBlocking() {
        let readiness = evaluator.evaluate(
            inputs(
                topology: topology(externalActive: true),
                keyboard: .absent,
                pointingDevice: .absent
            )
        )

        XCTAssertEqual(readiness.severity, .blocking)
        XCTAssertTrue(readiness.reasons.contains { $0.code == "external-keyboard-missing" })
        XCTAssertTrue(readiness.reasons.contains {
            $0.code == "external-pointing-device-missing"
        })
    }

    func testOnlineButInactiveExternalDisplayIsBlocking() {
        let readiness = evaluator.evaluate(
            inputs(topology: topology(externalActive: false))
        )

        XCTAssertEqual(readiness.severity, .blocking)
        XCTAssertTrue(readiness.reasons.contains { $0.code == "external-display-missing" })
    }

    private func inputs(
        mode: SessionMode = .agentDisplay,
        topology: DisplayTopology? = nil,
        assertionRunning: Bool = true,
        keyboard: DetectionState = .present,
        pointingDevice: DetectionState = .present
    ) -> ReadinessInputs {
        ReadinessInputs(
            sessionMode: mode,
            sessionRunning: true,
            lidClosed: true,
            isOnACPower: true,
            sleepDisabled: true,
            assertionProcessRunning: assertionRunning,
            topology: topology,
            externalKeyboard: keyboard,
            externalPointingDevice: pointingDevice,
            screenLockStatus: "After 5 minutes",
            topologyStable: true
        )
    }

    private func topology(externalActive: Bool) -> DisplayTopology {
        DisplayTopology(
            observedAt: Date(timeIntervalSince1970: 1_000),
            displays: [
                DisplayDescriptor(
                    id: 1,
                    isBuiltIn: true,
                    isOnline: true,
                    isActive: true,
                    isMain: !externalActive,
                    isMirrored: false,
                    width: 1_728,
                    height: 1_117
                ),
                DisplayDescriptor(
                    id: 2,
                    isBuiltIn: false,
                    isOnline: true,
                    isActive: externalActive,
                    isMain: externalActive,
                    isMirrored: false,
                    width: 1_920,
                    height: 1_080
                )
            ]
        )
    }
}
