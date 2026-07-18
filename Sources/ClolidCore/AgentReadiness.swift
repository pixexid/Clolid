import Foundation

public enum DetectionState: Equatable, Sendable {
    case present
    case absent
    case unknown(reason: String)
}

public struct ReadinessInputs: Equatable, Sendable {
    public let sessionMode: SessionMode
    public let sessionRunning: Bool
    public let lidClosed: Bool
    public let isOnACPower: Bool
    public let sleepDisabled: Bool
    public let assertionProcessRunning: Bool
    public let topology: DisplayTopology?
    public let externalKeyboard: DetectionState
    public let externalPointingDevice: DetectionState
    public let screenLockStatus: String
    public let topologyStable: Bool

    public init(
        sessionMode: SessionMode,
        sessionRunning: Bool,
        lidClosed: Bool,
        isOnACPower: Bool,
        sleepDisabled: Bool,
        assertionProcessRunning: Bool,
        topology: DisplayTopology?,
        externalKeyboard: DetectionState,
        externalPointingDevice: DetectionState,
        screenLockStatus: String,
        topologyStable: Bool
    ) {
        self.sessionMode = sessionMode
        self.sessionRunning = sessionRunning
        self.lidClosed = lidClosed
        self.isOnACPower = isOnACPower
        self.sleepDisabled = sleepDisabled
        self.assertionProcessRunning = assertionProcessRunning
        self.topology = topology
        self.externalKeyboard = externalKeyboard
        self.externalPointingDevice = externalPointingDevice
        self.screenLockStatus = screenLockStatus
        self.topologyStable = topologyStable
    }
}

public enum ReadinessSeverity: Int, Comparable, Sendable {
    case ready
    case advisory
    case blocking

    public static func < (lhs: ReadinessSeverity, rhs: ReadinessSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ReadinessReason: Equatable, Sendable {
    public let code: String
    public let severity: ReadinessSeverity
    public let title: String
    public let detail: String

    public init(code: String, severity: ReadinessSeverity, title: String, detail: String) {
        self.code = code
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

public struct AgentReadiness: Equatable, Sendable {
    public let severity: ReadinessSeverity
    public let summary: String
    public let reasons: [ReadinessReason]

    public init(severity: ReadinessSeverity, summary: String, reasons: [ReadinessReason]) {
        self.severity = severity
        self.summary = summary
        self.reasons = reasons
    }
}

public struct AgentReadinessEvaluator: Sendable {
    public init() {}

    public func evaluate(_ inputs: ReadinessInputs) -> AgentReadiness {
        guard inputs.sessionMode == .agentDisplay else {
            return AgentReadiness(severity: .ready, summary: "Standard mode", reasons: [])
        }

        var reasons: [ReadinessReason] = []

        if !inputs.sessionRunning {
            reasons.append(
                reason(
                    code: "session-stopped",
                    severity: .blocking,
                    title: "Session stopped",
                    detail: "Start a session before handing control to an agent."
                )
            )
        }
        if !inputs.sleepDisabled {
            reasons.append(
                reason(
                    code: "clamshell-sleep-enabled",
                    severity: .blocking,
                    title: "Closed-lid sleep is enabled",
                    detail: "Clolid has not confirmed the disablesleep setting."
                )
            )
        }
        if !inputs.assertionProcessRunning {
            reasons.append(
                reason(
                    code: "assertion-missing",
                    severity: .blocking,
                    title: "Wake assertion missing",
                    detail: "The Agent Display caffeinate process is not running."
                )
            )
        }

        if let topology = inputs.topology {
            if !topology.hasActiveExternalDisplay {
                reasons.append(
                    reason(
                        code: "external-display-missing",
                        severity: .blocking,
                        title: "External display missing",
                        detail: "Connect and activate an external display for the agent."
                    )
                )
            }
        } else {
            reasons.append(
                reason(
                    code: "topology-unavailable",
                    severity: .blocking,
                    title: "Display status unavailable",
                    detail: "Clolid could not confirm the current display topology."
                )
            )
        }

        if inputs.lidClosed && !inputs.topologyStable {
            reasons.append(
                reason(
                    code: "topology-settling",
                    severity: .advisory,
                    title: "Display is settling",
                    detail: "Wait for the display topology to stabilize."
                )
            )
        }
        if !inputs.lidClosed {
            reasons.append(
                reason(
                    code: "lid-open",
                    severity: .advisory,
                    title: "Lid is open",
                    detail: "Close the lid when the agent display is ready."
                )
            )
        }
        if !inputs.isOnACPower {
            reasons.append(
                reason(
                    code: "battery-power",
                    severity: .advisory,
                    title: "Running on battery",
                    detail: "Connect power for a long unattended session."
                )
            )
        }

        appendDetectionReason(
            inputs.externalKeyboard,
            code: "external-keyboard",
            deviceName: "External keyboard",
            reasons: &reasons
        )
        appendDetectionReason(
            inputs.externalPointingDevice,
            code: "external-pointing-device",
            deviceName: "External pointing device",
            reasons: &reasons
        )

        if inputs.screenLockStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || inputs.screenLockStatus.localizedCaseInsensitiveContains("unknown") {
            reasons.append(
                reason(
                    code: "screen-lock-unknown",
                    severity: .advisory,
                    title: "Screen Lock status unknown",
                    detail: "Review the effective Screen Lock setting before unattended use."
                )
            )
        }

        let severity = reasons.map(\.severity).max() ?? .ready
        let summary: String
        switch severity {
        case .ready:
            summary = "Ready"
        case .advisory:
            summary = "Ready with advisories"
        case .blocking:
            summary = "Not ready"
        }
        return AgentReadiness(severity: severity, summary: summary, reasons: reasons)
    }

    private func appendDetectionReason(
        _ state: DetectionState,
        code: String,
        deviceName: String,
        reasons: inout [ReadinessReason]
    ) {
        switch state {
        case .present:
            return
        case .absent:
            reasons.append(
                reason(
                    code: "\(code)-missing",
                    severity: .blocking,
                    title: "\(deviceName) missing",
                    detail: "Connect a \(deviceName.lowercased()) before closing the lid."
                )
            )
        case .unknown(let reasonText):
            reasons.append(
                reason(
                    code: "\(code)-unknown",
                    severity: .advisory,
                    title: "\(deviceName) not verified",
                    detail: reasonText
                )
            )
        }
    }

    private func reason(
        code: String,
        severity: ReadinessSeverity,
        title: String,
        detail: String
    ) -> ReadinessReason {
        ReadinessReason(code: code, severity: severity, title: title, detail: detail)
    }
}
