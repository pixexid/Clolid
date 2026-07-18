import ClolidCore
import Foundation

public protocol ScheduledTransition: AnyObject {
    func cancel()
}

public protocol LidTransitionScheduling {
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> any ScheduledTransition
}

private final class DispatchScheduledTransition: ScheduledTransition {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

public struct MainQueueLidTransitionScheduler: LidTransitionScheduling {
    public init() {}

    public func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> any ScheduledTransition {
        let workItem = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0), execute: workItem)
        return DispatchScheduledTransition(workItem: workItem)
    }
}

public protocol LidTransitionControllerDelegate: AnyObject {
    func lidTransitionController(
        _ controller: LidTransitionController,
        didRequest effect: LidRuntimeEffect,
        state: LidTransitionState
    )
    func lidTransitionController(
        _ controller: LidTransitionController,
        topologyCaptureDidFail message: String,
        state: LidTransitionState
    )
    func lidTransitionController(
        _ controller: LidTransitionController,
        runtimeActionDidFail message: String,
        state: LidTransitionState
    )
}

public final class LidTransitionController {
    public weak var delegate: (any LidTransitionControllerDelegate)?
    public private(set) var state = LidTransitionState()
    public private(set) var lastCaptureSucceeded = false

    private let reducer: LidTransitionReducer
    private let topologyProvider: any DisplayTopologyProviding
    private let wakePulseController: any WakePulseControlling
    private let scheduler: any LidTransitionScheduling
    private var preferences = LidTransitionPreferences(
        automaticDisplaySleepEnabled: true,
        wakePulseEnabled: false,
        missingDisplayWarningEnabled: false,
        requireACPower: false
    )
    private var generation = 0
    private struct ScheduledRefresh {
        let id: UUID
        let transition: any ScheduledTransition
    }
    private var scheduledRefreshes: [TimeInterval: ScheduledRefresh] = [:]

    public init(
        reducer: LidTransitionReducer = LidTransitionReducer(),
        topologyProvider: any DisplayTopologyProviding = CoreGraphicsDisplayTopologyProvider(),
        wakePulseController: any WakePulseControlling = WakePulseController(),
        scheduler: any LidTransitionScheduling = MainQueueLidTransitionScheduler()
    ) {
        self.reducer = reducer
        self.topologyProvider = topologyProvider
        self.wakePulseController = wakePulseController
        self.scheduler = scheduler
    }

    @discardableResult
    public func start(
        mode: SessionMode,
        lidClosed: Bool,
        isOnACPower: Bool,
        preferences: LidTransitionPreferences,
        at: Date = Date()
    ) -> Bool {
        self.preferences = preferences
        invalidateScheduledRefreshes()

        if mode.policy.supportsWakePulse,
           preferences.wakePulseEnabled,
           !wakePulseController.prepareRecoveryInputAccess() {
            delegate?.lidTransitionController(
                self,
                runtimeActionDidFail: "Accessibility permission is required for closed-lid display recovery.",
                state: state
            )
        }

        guard let topology = captureTopology(at: at) else {
            return false
        }

        send(.sessionStarted(mode: mode, topology: topology, at: at))
        send(.powerChanged(isOnAC: isOnACPower, at: at))
        if lidClosed {
            send(.lidClosed(topology: topology, at: at))
        }
        return state.sessionRunning
    }

    public func stop(at: Date = Date()) {
        invalidateScheduledRefreshes()
        wakePulseController.stop()
        lastCaptureSucceeded = false
        if state.sessionRunning {
            send(.sessionStopped(at: at))
        }
    }

    public func updateMode(
        _ mode: SessionMode,
        preferences: LidTransitionPreferences,
        at: Date = Date()
    ) {
        self.preferences = preferences
        if !mode.policy.supportsWakePulse {
            wakePulseController.stop()
        }
        send(.sessionModeChanged(mode: mode, at: at))
    }

    @discardableResult
    public func lidChanged(
        closed: Bool,
        preferences: LidTransitionPreferences,
        at: Date = Date()
    ) -> Bool {
        self.preferences = preferences
        guard let topology = captureTopology(at: at) else {
            return false
        }

        invalidateScheduledRefreshes()
        if closed {
            send(.lidClosed(topology: topology, at: at))
        } else {
            send(.lidOpened(topology: topology, at: at))
        }
        return true
    }

    public func refreshTopology(
        preferences: LidTransitionPreferences,
        at: Date = Date()
    ) {
        self.preferences = preferences
        guard let topology = captureTopology(at: at) else {
            return
        }
        send(.topologyChanged(topology))
    }

    public func powerChanged(
        isOnACPower: Bool,
        preferences: LidTransitionPreferences,
        at: Date = Date()
    ) {
        self.preferences = preferences
        send(.powerChanged(isOnAC: isOnACPower, at: at))
    }

    private func captureTopology(at observedAt: Date) -> DisplayTopology? {
        do {
            let topology = try topologyProvider.snapshot(at: observedAt)
            lastCaptureSucceeded = true
            return topology
        } catch {
            lastCaptureSucceeded = false
            delegate?.lidTransitionController(
                self,
                topologyCaptureDidFail: error.localizedDescription,
                state: state
            )
            return nil
        }
    }

    private func send(_ event: LidRuntimeEvent) {
        let effects = reducer.reduce(state: &state, event: event, preferences: preferences)
        for effect in effects {
            execute(effect)
        }
    }

    private func execute(_ effect: LidRuntimeEffect) {
        switch effect {
        case .refreshTopology(let delay):
            scheduleTopologyRefresh(after: delay)

        case .issueWakePulse(let duration):
            do {
                try wakePulseController.issue(duration: duration)
            } catch {
                send(.wakePulseFailed(at: Date()))
                delegate?.lidTransitionController(
                    self,
                    runtimeActionDidFail: "Unable to wake the agent display: \(error.localizedDescription)",
                    state: state
                )
            }

        case .issueRecoveryWake(let duration):
            do {
                try wakePulseController.issueRecovery(duration: duration)
            } catch {
                delegate?.lidTransitionController(
                    self,
                    runtimeActionDidFail: "Unable to recover the agent display: \(error.localizedDescription)",
                    state: state
                )
            }

        case .sleepAllDisplays,
             .publishReadiness,
             .notifyOnce,
             .requestSessionStop,
             .recordEvent:
            delegate?.lidTransitionController(self, didRequest: effect, state: state)
        }
    }

    private func scheduleTopologyRefresh(after delay: TimeInterval) {
        guard scheduledRefreshes[delay] == nil else {
            return
        }

        let scheduledGeneration = generation
        let refreshID = UUID()
        let transition = scheduler.schedule(after: delay) { [weak self] in
            guard let self else {
                return
            }
            if self.scheduledRefreshes[delay]?.id == refreshID {
                self.scheduledRefreshes[delay] = nil
            }
            guard self.generation == scheduledGeneration, self.state.sessionRunning else {
                return
            }
            self.refreshTopology(preferences: self.preferences)
        }
        scheduledRefreshes[delay] = ScheduledRefresh(id: refreshID, transition: transition)
    }

    private func invalidateScheduledRefreshes() {
        generation += 1
        scheduledRefreshes.values.forEach { $0.transition.cancel() }
        scheduledRefreshes.removeAll()
    }
}
