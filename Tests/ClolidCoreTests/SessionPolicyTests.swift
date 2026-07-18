import XCTest
@testable import ClolidCore

final class SessionPolicyTests: XCTestCase {
    func testStandardModeUsesExistingAssertionProfile() {
        XCTAssertEqual(SessionMode.standard.policy.caffeinateArguments, ["-i", "-s"])
        XCTAssertTrue(SessionMode.standard.policy.permitsAutomaticDisplaySleep)
        XCTAssertFalse(SessionMode.standard.policy.supportsWakePulse)
    }

    func testAgentDisplayModePreventsDisplaySleep() {
        XCTAssertEqual(SessionMode.agentDisplay.policy.caffeinateArguments, ["-d", "-i", "-s"])
        XCTAssertFalse(SessionMode.agentDisplay.policy.permitsAutomaticDisplaySleep)
        XCTAssertTrue(SessionMode.agentDisplay.policy.supportsWakePulse)
    }

    func testMissingOrMalformedPersistedModeDefaultsToStandard() {
        XCTAssertEqual(SessionMode.normalized(rawValue: nil), .standard)
        XCTAssertEqual(SessionMode.normalized(rawValue: "unsupported"), .standard)
    }

    func testPersistedAgentDisplayModeRoundTrips() {
        XCTAssertEqual(SessionMode.normalized(rawValue: SessionMode.agentDisplay.rawValue), .agentDisplay)
    }
}
