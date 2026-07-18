import Foundation

public enum SessionMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard
    case agentDisplay

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .standard:
            return "Standard"
        case .agentDisplay:
            return "Agent Display"
        }
    }

    public static func normalized(rawValue: String?) -> SessionMode {
        rawValue.flatMap(SessionMode.init(rawValue:)) ?? .standard
    }

    public var policy: SessionPolicy {
        switch self {
        case .standard:
            return SessionPolicy(
                caffeinateArguments: ["-i", "-s"],
                permitsAutomaticDisplaySleep: true,
                supportsWakePulse: false
            )
        case .agentDisplay:
            return SessionPolicy(
                caffeinateArguments: ["-d", "-i", "-s"],
                permitsAutomaticDisplaySleep: false,
                supportsWakePulse: true
            )
        }
    }
}

public struct SessionPolicy: Equatable, Sendable {
    public let caffeinateArguments: [String]
    public let permitsAutomaticDisplaySleep: Bool
    public let supportsWakePulse: Bool

    public init(
        caffeinateArguments: [String],
        permitsAutomaticDisplaySleep: Bool,
        supportsWakePulse: Bool
    ) {
        self.caffeinateArguments = caffeinateArguments
        self.permitsAutomaticDisplaySleep = permitsAutomaticDisplaySleep
        self.supportsWakePulse = supportsWakePulse
    }
}
