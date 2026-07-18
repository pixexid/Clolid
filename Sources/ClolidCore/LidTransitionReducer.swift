import Foundation

public struct DisplayTransitionConfiguration: Equatable, Sendable {
    public let settleDelay: TimeInterval
    public let sampleInterval: TimeInterval
    public let requiredStableSamples: Int
    public let missingDisplayWarningDelay: TimeInterval
    public let wakePulseDuration: TimeInterval

    public init(
        settleDelay: TimeInterval = 0.5,
        sampleInterval: TimeInterval = 0.5,
        requiredStableSamples: Int = 3,
        missingDisplayWarningDelay: TimeInterval = 5,
        wakePulseDuration: TimeInterval = 5
    ) {
        precondition(settleDelay >= 0)
        precondition(sampleInterval > 0)
        precondition(requiredStableSamples >= 2)
        precondition(missingDisplayWarningDelay >= 0)
        precondition(wakePulseDuration > 0)

        self.settleDelay = settleDelay
        self.sampleInterval = sampleInterval
        self.requiredStableSamples = requiredStableSamples
        self.missingDisplayWarningDelay = missingDisplayWarningDelay
        self.wakePulseDuration = wakePulseDuration
    }
}

public struct LidTransitionPreferences: Equatable, Sendable {
    public let automaticDisplaySleepEnabled: Bool
    public let wakePulseEnabled: Bool
    public let missingDisplayWarningEnabled: Bool
    public let requireACPower: Bool

    public init(
        automaticDisplaySleepEnabled: Bool,
        wakePulseEnabled: Bool,
        missingDisplayWarningEnabled: Bool,
        requireACPower: Bool
    ) {
        self.automaticDisplaySleepEnabled = automaticDisplaySleepEnabled
        self.wakePulseEnabled = wakePulseEnabled
        self.missingDisplayWarningEnabled = missingDisplayWarningEnabled
        self.requireACPower = requireACPower
    }
}

public enum LidPhase: Equatable, Sendable {
    case open
    case settling(LidCloseContext)
    case closed(LidCloseContext)
}

public struct LidCloseContext: Equatable, Sendable {
    public let closedAt: Date
    public let preCloseTopology: DisplayTopology
    public internal(set) var latestTopology: DisplayTopology
    public internal(set) var lastCountedStableSampleAt: Date
    public internal(set) var consecutiveStableSamples: Int
    public internal(set) var consecutiveNoExternalSamples: Int
    public internal(set) var topologyStable: Bool
    public let externalDisplayAvailableAtClose: Bool
    public internal(set) var externalDisplayObservedDuringTransition: Bool
    public internal(set) var automaticSleepEvaluated: Bool
    public internal(set) var automaticSleepIssued: Bool
    public internal(set) var wakePulseIssued: Bool
    public internal(set) var postSettleWakePulseIssued: Bool
    public internal(set) var recoveryWakeIssued: Bool
    public internal(set) var missingDisplayWarningIssued: Bool

    init(
        closedAt: Date,
        preCloseTopology: DisplayTopology,
        latestTopology: DisplayTopology? = nil
    ) {
        let latestTopology = latestTopology ?? preCloseTopology

        self.closedAt = closedAt
        self.preCloseTopology = preCloseTopology
        self.latestTopology = latestTopology
        self.lastCountedStableSampleAt = latestTopology.observedAt
        self.consecutiveStableSamples = 1
        self.consecutiveNoExternalSamples = latestTopology.hasExternalOnlineDisplay ? 0 : 1
        self.topologyStable = false
        self.externalDisplayAvailableAtClose = latestTopology.hasExternalOnlineDisplay
        self.externalDisplayObservedDuringTransition =
            preCloseTopology.hasExternalOnlineDisplay || latestTopology.hasExternalOnlineDisplay
        self.automaticSleepEvaluated = false
        self.automaticSleepIssued = false
        self.wakePulseIssued = false
        self.postSettleWakePulseIssued = false
        self.recoveryWakeIssued = false
        self.missingDisplayWarningIssued = false
    }
}

public struct LidTransitionState: Equatable, Sendable {
    public internal(set) var sessionMode: SessionMode
    public internal(set) var sessionRunning: Bool
    public internal(set) var phase: LidPhase
    public internal(set) var latestTopology: DisplayTopology?
    public internal(set) var isOnACPower: Bool

    public init() {
        sessionMode = .standard
        sessionRunning = false
        phase = .open
        latestTopology = nil
        isOnACPower = false
    }

    init(
        sessionMode: SessionMode = .standard,
        sessionRunning: Bool = false,
        phase: LidPhase = .open,
        latestTopology: DisplayTopology? = nil,
        isOnACPower: Bool = false
    ) {
        self.sessionMode = sessionMode
        self.sessionRunning = sessionRunning
        self.phase = phase
        self.latestTopology = latestTopology
        self.isOnACPower = isOnACPower
    }
}

public enum LidRuntimeEvent: Equatable, Sendable {
    case sessionStarted(mode: SessionMode, topology: DisplayTopology, at: Date)
    case sessionStopped(at: Date)
    case sessionModeChanged(mode: SessionMode, at: Date)
    case wakePulseFailed(at: Date)
    case lidOpened(topology: DisplayTopology, at: Date)
    case lidClosed(topology: DisplayTopology, at: Date)
    case topologyChanged(DisplayTopology)
    case settleTimerFired(at: Date)
    case powerChanged(isOnAC: Bool, at: Date)
}

public struct DiagnosticEvent: Equatable, Sendable {
    public let at: Date
    public let category: String
    public let code: String
    public let message: String

    public init(at: Date, category: String, code: String, message: String) {
        self.at = at
        self.category = category
        self.code = code
        self.message = message
    }
}

public enum LidRuntimeEffect: Equatable, Sendable {
    case refreshTopology(after: TimeInterval)
    case sleepAllDisplays
    case issueWakePulse(duration: TimeInterval)
    case issueRecoveryWake(duration: TimeInterval)
    case publishReadiness
    case notifyOnce(code: String, title: String, body: String)
    case requestSessionStop(reason: String)
    case recordEvent(DiagnosticEvent)
}

public struct LidTransitionReducer: Sendable {
    public let configuration: DisplayTransitionConfiguration

    public init(configuration: DisplayTransitionConfiguration = DisplayTransitionConfiguration()) {
        self.configuration = configuration
    }

    public func reduce(
        state: inout LidTransitionState,
        event: LidRuntimeEvent,
        preferences: LidTransitionPreferences
    ) -> [LidRuntimeEffect] {
        switch event {
        case .sessionStarted(let mode, let topology, _):
            state.sessionMode = mode
            state.sessionRunning = true
            state.phase = .open
            state.latestTopology = topology
            return [.publishReadiness]

        case .sessionStopped:
            state.sessionRunning = false
            state.phase = .open
            return [.publishReadiness]

        case .sessionModeChanged(let mode, _):
            state.sessionMode = mode
            var effects: [LidRuntimeEffect] = [.publishReadiness]

            switch state.phase {
            case .open:
                break
            case .settling(var context):
                if shouldIssueWakePulse(context: context, mode: mode, preferences: preferences) {
                    context.wakePulseIssued = true
                    effects.append(.issueWakePulse(duration: configuration.wakePulseDuration))
                }
                state.phase = .settling(context)
            case .closed(var context):
                if shouldIssueWakePulse(context: context, mode: mode, preferences: preferences) {
                    context.wakePulseIssued = true
                    effects.append(.issueWakePulse(duration: configuration.wakePulseDuration))
                }
                state.phase = .closed(context)
            }
            return effects

        case .wakePulseFailed:
            switch state.phase {
            case .open:
                return []
            case .settling(var context):
                resetFailedWakePulse(in: &context)
                state.phase = .settling(context)
            case .closed(var context):
                resetFailedWakePulse(in: &context)
                state.phase = .closed(context)
            }
            return [.publishReadiness]

        case .lidOpened(let topology, _):
            state.phase = .open
            state.latestTopology = topology
            return [.publishReadiness]

        case .lidClosed(let topology, let at):
            guard state.sessionRunning, case .open = state.phase else {
                return []
            }

            let preCloseTopology = state.latestTopology ?? topology
            var context = LidCloseContext(
                closedAt: at,
                preCloseTopology: preCloseTopology,
                latestTopology: topology
            )
            var effects: [LidRuntimeEffect] = [
                .publishReadiness,
                .refreshTopology(after: configuration.settleDelay)
            ]

            if shouldIssueWakePulse(context: context, mode: state.sessionMode, preferences: preferences) {
                context.wakePulseIssued = true
                effects.append(.issueWakePulse(duration: configuration.wakePulseDuration))
            }

            if state.sessionMode == .agentDisplay,
               preferences.missingDisplayWarningEnabled,
               !topology.hasExternalOnlineDisplay {
                effects.append(.refreshTopology(after: configuration.missingDisplayWarningDelay))
            }

            state.latestTopology = topology
            state.phase = .settling(context)
            return effects

        case .topologyChanged(let topology):
            guard state.latestTopology.map({ topology.observedAt > $0.observedAt }) ?? true else {
                return []
            }
            state.latestTopology = topology
            guard state.sessionRunning else {
                return [.publishReadiness]
            }

            switch state.phase {
            case .open:
                return [.publishReadiness]
            case .settling(var context), .closed(var context):
                let wakePulseHadBeenIssued = context.wakePulseIssued
                let externalDisplayWasOnline = context.latestTopology.hasExternalOnlineDisplay
                update(&context, with: topology)
                var effects: [LidRuntimeEffect] = [.publishReadiness]

                if shouldIssueWakePulse(context: context, mode: state.sessionMode, preferences: preferences) {
                    context.wakePulseIssued = true
                    effects.append(.issueWakePulse(duration: configuration.wakePulseDuration))
                }

                if shouldIssueRecoveryWake(
                    context: context,
                    externalDisplayWasOnline: externalDisplayWasOnline,
                    mode: state.sessionMode,
                    preferences: preferences
                ) {
                    context.recoveryWakeIssued = true
                    effects.append(.issueRecoveryWake(duration: configuration.wakePulseDuration))
                    effects.append(.refreshTopology(after: configuration.sampleInterval))
                }

                appendMissingDisplayWarningIfNeeded(
                    context: &context,
                    mode: state.sessionMode,
                    at: topology.observedAt,
                    preferences: preferences,
                    effects: &effects
                )

                if context.topologyStable {
                    if wakePulseHadBeenIssued,
                       shouldIssuePostSettleWakePulse(
                           context: context,
                           mode: state.sessionMode,
                           preferences: preferences
                       ) {
                        context.postSettleWakePulseIssued = true
                        effects.append(.issueWakePulse(duration: configuration.wakePulseDuration))
                    }
                    appendAutomaticDisplaySleepDecision(
                        context: &context,
                        mode: state.sessionMode,
                        preferences: preferences,
                        effects: &effects
                    )
                    state.phase = .closed(context)
                } else {
                    state.phase = .settling(context)
                    effects.append(.refreshTopology(after: configuration.sampleInterval))
                }

                return effects
            }

        case .settleTimerFired(let at):
            switch state.phase {
            case .open:
                return []
            case .settling(var context), .closed(var context):
                var effects: [LidRuntimeEffect] = []
                appendMissingDisplayWarningIfNeeded(
                    context: &context,
                    mode: state.sessionMode,
                    at: at,
                    preferences: preferences,
                    effects: &effects
                )

                if case .settling = state.phase {
                    state.phase = .settling(context)
                } else {
                    state.phase = .closed(context)
                }
                return effects
            }

        case .powerChanged(let isOnAC, _):
            state.isOnACPower = isOnAC
            var effects: [LidRuntimeEffect] = [.publishReadiness]
            if state.sessionRunning && preferences.requireACPower && !isOnAC {
                effects.append(.requestSessionStop(reason: "External power disconnected."))
            }
            return effects
        }
    }

    private func update(_ context: inout LidCloseContext, with topology: DisplayTopology) {
        if topology.externalOnlineDisplayIDs == context.latestTopology.externalOnlineDisplayIDs {
            if topology.observedAt.timeIntervalSince(context.lastCountedStableSampleAt) >= configuration.sampleInterval {
                context.consecutiveStableSamples += 1
                context.lastCountedStableSampleAt = topology.observedAt
            }
        } else {
            context.consecutiveStableSamples = 1
            context.lastCountedStableSampleAt = topology.observedAt
        }

        if topology.hasExternalOnlineDisplay {
            context.consecutiveNoExternalSamples = 0
            context.externalDisplayObservedDuringTransition = true
        } else {
            context.consecutiveNoExternalSamples += 1
        }

        context.latestTopology = topology
        context.topologyStable = context.consecutiveStableSamples >= configuration.requiredStableSamples
    }

    private func shouldIssueWakePulse(
        context: LidCloseContext,
        mode: SessionMode,
        preferences: LidTransitionPreferences
    ) -> Bool {
        mode.policy.supportsWakePulse
            && preferences.wakePulseEnabled
            && !context.wakePulseIssued
            && context.latestTopology.hasExternalOnlineDisplay
    }

    private func shouldIssuePostSettleWakePulse(
        context: LidCloseContext,
        mode: SessionMode,
        preferences: LidTransitionPreferences
    ) -> Bool {
        mode.policy.supportsWakePulse
            && preferences.wakePulseEnabled
            && context.externalDisplayAvailableAtClose
            && context.wakePulseIssued
            && !context.postSettleWakePulseIssued
            && context.topologyStable
            && context.latestTopology.hasExternalOnlineDisplay
    }

    private func shouldIssueRecoveryWake(
        context: LidCloseContext,
        externalDisplayWasOnline: Bool,
        mode: SessionMode,
        preferences: LidTransitionPreferences
    ) -> Bool {
        mode.policy.supportsWakePulse
            && preferences.wakePulseEnabled
            && context.externalDisplayAvailableAtClose
            && context.wakePulseIssued
            && externalDisplayWasOnline
            && !context.latestTopology.hasExternalOnlineDisplay
            && !context.recoveryWakeIssued
    }

    private func resetFailedWakePulse(in context: inout LidCloseContext) {
        if context.postSettleWakePulseIssued {
            context.postSettleWakePulseIssued = false
        } else {
            context.wakePulseIssued = false
        }
    }

    private func appendAutomaticDisplaySleepDecision(
        context: inout LidCloseContext,
        mode: SessionMode,
        preferences: LidTransitionPreferences,
        effects: inout [LidRuntimeEffect]
    ) {
        guard !context.automaticSleepEvaluated else {
            return
        }

        context.automaticSleepEvaluated = true
        let shouldSleep = mode.policy.permitsAutomaticDisplaySleep
            && preferences.automaticDisplaySleepEnabled
            && !context.preCloseTopology.hasExternalOnlineDisplay
            && !context.externalDisplayObservedDuringTransition
            && context.consecutiveNoExternalSamples >= configuration.requiredStableSamples

        if shouldSleep {
            context.automaticSleepIssued = true
            effects.append(.sleepAllDisplays)
        }
    }

    private func appendMissingDisplayWarningIfNeeded(
        context: inout LidCloseContext,
        mode: SessionMode,
        at: Date,
        preferences: LidTransitionPreferences,
        effects: inout [LidRuntimeEffect]
    ) {
        guard mode == .agentDisplay,
              preferences.missingDisplayWarningEnabled,
              !context.missingDisplayWarningIssued,
              !context.latestTopology.hasExternalOnlineDisplay,
              at.timeIntervalSince(context.closedAt) >= configuration.missingDisplayWarningDelay
        else {
            return
        }

        context.missingDisplayWarningIssued = true
        effects.append(
            .notifyOnce(
                code: "agent-display-missing",
                title: "Agent display missing",
                body: "No external display is available for computer-use agents."
            )
        )
    }
}
