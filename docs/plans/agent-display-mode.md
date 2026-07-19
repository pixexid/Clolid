# Agent Display Mode Implementation Plan

**Status:** Proposed engineering handoff  
**Epic:** [#2 — Add reliable Agent Display Mode for unattended closed-lid automation](https://github.com/pixexid/Clolid/issues/2)  
**Repository:** `pixexid/Clolid`  
**Primary implementer:** Codex  
**Last updated:** 2026-07-17

## 1. Executive summary

Clolid already keeps macOS computationally awake with the lid closed by combining `pmset disablesleep` and `caffeinate`. That solves system sleep, but it does not guarantee that WindowServer retains a stable external framebuffer for screenshot-based Computer Use.

The observed failure is a closed-lid transition where a portable USB-C display briefly disappears during USB-C/DisplayPort renegotiation. If Clolid observes that transient gap as “no external display” and calls `pmset displaysleepnow`, macOS sleeps all connected displays. The external monitor can report **No Signal**, and screenshot-based agents can receive black frames even though the processes and unlocked login session remain alive.

This plan adds a first-class **Agent Display Mode** with four core properties:

1. It uses a display-sleep-preventing assertion profile: `caffeinate -d -i -s`.
2. It never automatically invokes `pmset displaysleepnow`.
3. It treats lid and display changes as a debounced state machine rather than isolated polling observations.
4. It reports whether the machine is ready for supported closed-lid agent operation and produces bounded diagnostics when it is not.

The implementation should remain native, dependency-free, testable, and conservative about macOS security and hardware requirements.

---

## 2. Product context

### 2.1 Target workflow

The intended unattended setup is:

- MacBook connected to external power;
- external keyboard and mouse/trackpad connected and approved;
- a physical external display or HDMI dummy/EDID adapter connected;
- the agent display configured as the macOS Main Display;
- Clolid running with Agent Display Mode enabled;
- the selected Screen Lock policy applied;
- `llm-collab` handling durable multi-agent coordination;
- AX doorbells handling normal focus-independent agent-to-agent messaging;
- screenshot/keyboard Computer Use handling visible supervision and recovery.

Clolid owns only the local power, display-readiness, and session-policy layer. It must not claim control over third-party agent capture implementations or bypass macOS accessory approval, privacy permissions, or lock/security controls.

### 2.2 Current implementation

The current application is primarily implemented in `Sources/Clolid/main.swift` and does the following during an active session:

```bash
sudo pmset -a disablesleep 1
caffeinate -i -s
```

It polls `AppleClamshellState`, reads external-display information, and can call:

```bash
pmset displaysleepnow
```

when the lid closes and no external display is detected.

The current release already contains a synchronous `CGGetOnlineDisplayList` guard intended to avoid blanking an external display. That guard reduces the common failure but does not eliminate a transient topology race.

### 2.3 Root cause

The current decision is based on a momentary snapshot:

```text
lid just closed
    + external display currently absent
    = sleep displays now
```

That is unsafe because a USB-C monitor can briefly disappear during the exact lid-close interval. `pmset displaysleepnow` is not scoped to the built-in panel. Once called, it can blank the external display that is about to reconnect.

The correct decision must incorporate history:

```text
Was an external display present immediately before the lid closed?
Did the topology remain stably absent after a settling interval?
Which session mode is active?
Has this transition already issued a recovery action?
```

---

## 3. Goals

### 3.1 Required outcomes

- Add an explicit Agent Display Mode for unattended automation.
- Keep Clolid’s owned system and display assertions active for the session.
- Never automatically sleep displays in Agent Display Mode.
- Prevent transient display renegotiation from triggering all-display sleep in Standard mode.
- Preserve the safe stop path:
  - terminate only Clolid-owned assertion processes;
  - restore `pmset -a disablesleep 0`;
  - restore the Screen Lock snapshot when applicable.
- Surface a truthful readiness state with actionable reasons.
- Add bounded, redacted diagnostics.
- Add automated tests for power/assertion policy and lid/display transitions.
- Update user documentation with supported hardware and setup requirements.

### 3.2 Quality goals

- No new third-party runtime dependencies.
- No private display-management APIs.
- No hot-path use of `system_profiler`.
- No repeated wake loop.
- No silent guessing when a prerequisite cannot be reliably detected.
- No UI-thread blocking during diagnostics or slow system inspection.
- No regression to existing start-at-login and Screen Lock behavior.

---

## 4. Non-goals

- Implementing a virtual display driver.
- Creating or configuring EDID firmware.
- Automatically changing the macOS Main Display through private APIs.
- Guaranteeing supported clamshell behavior without external power, approved display, keyboard, and mouse/trackpad.
- Bypassing Screen Lock, accessory approval, Accessibility, or Screen Recording permissions.
- Detecting whether every third-party Computer Use implementation can capture the display.
- Replacing `llm-collab`, AX doorbells, or agent-specific communication logic.
- Keeping a Mac awake while enclosed in a bag or other unsafe thermal environment.

---

## 5. Product model

## 5.1 Session modes

Introduce a persisted enum:

```swift
enum SessionMode: String, CaseIterable, Codable, Identifiable {
    case standard
    case agentDisplay
}
```

Suggested user-facing names:

- `Standard`
- `Agent Display`

### Standard mode

Purpose: normal closed-lid desk use.

Behavior:

- retain system-awake behavior;
- use a hardened automatic display-sleep policy;
- allow the manual **Sleep display now** command;
- preserve the existing `Sleep display on lid close` preference only in this mode.

### Agent Display mode

Purpose: unattended automation requiring a persistent external framebuffer.

Behavior:

- use `caffeinate -d -i -s`;
- never automatically call `pmset displaysleepnow`;
- optionally issue one bounded wake pulse per close/reconnect transition;
- calculate and display agent readiness;
- hide or disable contradictory automatic-display-sleep controls;
- retain the manual **Sleep display now** command only if the UI clearly warns that it sleeps the agent display too.

## 5.2 Backward-compatible default

For existing installations:

- default `SessionMode` to `standard`;
- preserve the existing `SleepDisplayOnLidClose` value for Standard mode;
- do not silently switch existing users into Agent Display mode;
- do not silently change Screen Lock policy;
- display a one-time informational callout describing Agent Display mode when first introduced.

For new installations, Standard mode remains the safest default unless product testing justifies otherwise.

---

## 6. Proposed architecture

The current monolithic executable makes system behavior difficult to test. Extract only the pure behavior needed for this epic.

## 6.1 Swift package target structure

Recommended minimal structure:

```text
Package.swift
Sources/
├── Clolid/
│   ├── main.swift
│   ├── System/
│   │   ├── CommandRunner.swift
│   │   ├── DisplayTopologyProvider.swift
│   │   ├── HIDReadinessProvider.swift
│   │   └── PowerStateProvider.swift
│   ├── Runtime/
│   │   ├── SessionAssertionController.swift
│   │   ├── LidRuntimeCoordinator.swift
│   │   └── DiagnosticsCollector.swift
│   └── Resources/
└── ClolidCore/
    ├── SessionMode.swift
    ├── SessionPolicy.swift
    ├── DisplayTopology.swift
    ├── LidTransitionReducer.swift
    ├── AgentReadiness.swift
    └── DiagnosticsModel.swift
Tests/
└── ClolidCoreTests/
    ├── SessionPolicyTests.swift
    ├── LidTransitionReducerTests.swift
    ├── AgentReadinessTests.swift
    └── DiagnosticsRedactionTests.swift
```

Update `Package.swift` to add an internal `ClolidCore` target and a test target. The executable depends on `ClolidCore`; no public library product is required.

Do not move unrelated SwiftUI views merely for aesthetic organization. The extraction exists to isolate deterministic policy and state transitions.

## 6.2 Dependency direction

```text
SwiftUI/AppKit UI
       │
       ▼
Runtime coordinators and system adapters
       │
       ▼
Pure ClolidCore policies and reducers
```

`ClolidCore` must not execute shell commands or depend on AppKit. It receives snapshots and emits decisions.

---

## 7. Core data model

## 7.1 Display topology snapshot

```swift
struct DisplayDescriptor: Equatable, Sendable {
    let id: UInt32
    let name: String?
    let isBuiltIn: Bool
    let isOnline: Bool
    let isActive: Bool
    let isMain: Bool
    let isMirrored: Bool
    let width: Int
    let height: Int
    let scale: Double?
}

struct DisplayTopology: Equatable, Sendable {
    let observedAt: Date
    let displays: [DisplayDescriptor]

    var externalOnlineDisplays: [DisplayDescriptor] {
        displays.filter { !$0.isBuiltIn && $0.isOnline }
    }

    var hasExternalOnlineDisplay: Bool {
        !externalOnlineDisplays.isEmpty
    }

    var hasMainExternalDisplay: Bool {
        externalOnlineDisplays.contains(where: \.isMain)
    }
}
```

The exact fields may be adjusted to match available APIs, but the pure model must distinguish:

- built-in versus external;
- online versus active;
- main versus secondary;
- mirrored versus independent;
- stable identity across samples where possible.

## 7.2 Tri-state prerequisite values

Some prerequisites cannot always be proven. Model them explicitly:

```swift
enum DetectionState: Equatable, Sendable {
    case present
    case absent
    case unknown(reason: String)
}
```

Use this for external keyboard, external pointing device, and any accessory-approval inference.

## 7.3 Readiness snapshot

```swift
struct ReadinessInputs: Equatable, Sendable {
    let sessionMode: SessionMode
    let sessionRunning: Bool
    let lidClosed: Bool
    let isOnACPower: Bool
    let sleepDisabled: Bool
    let assertionProcessRunning: Bool
    let topology: DisplayTopology
    let externalKeyboard: DetectionState
    let externalPointingDevice: DetectionState
    let screenLockStatus: String
    let topologyStable: Bool
}
```

```swift
enum ReadinessSeverity: Int, Comparable, Sendable {
    case ready
    case advisory
    case blocking
}

struct ReadinessReason: Equatable, Sendable {
    let code: String
    let severity: ReadinessSeverity
    let title: String
    let detail: String
}

struct AgentReadiness: Equatable, Sendable {
    let severity: ReadinessSeverity
    let summary: String
    let reasons: [ReadinessReason]
}
```

Readiness should be deterministic and unit-tested.

---

## 8. Session assertion controller

## 8.1 Assertion profiles

Define the process arguments in pure policy:

```swift
struct SessionPolicy: Equatable, Sendable {
    let caffeinateArguments: [String]
    let permitsAutomaticDisplaySleep: Bool
    let supportsWakePulse: Bool
}

extension SessionMode {
    var policy: SessionPolicy {
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
```

## 8.2 Process ownership

Replace ad hoc process handling with a focused `SessionAssertionController` that owns:

- the active `Process` instance;
- PID persistence under `~/Library/Caches/Clolid/`;
- process arguments used for the current session;
- start time;
- clean termination;
- stale-PID cleanup.

Requirements:

- terminate only the PID written by Clolid;
- validate that a stale PID still belongs to a `caffeinate` process before signaling it;
- remove the PID file after successful cleanup;
- never call broad `pkill caffeinate` from the app;
- expose current PID and arguments to diagnostics;
- restart the process atomically if the session mode changes while running.

Suggested restart sequence:

1. start the replacement assertion process;
2. confirm it is running;
3. terminate the old owned process;
4. persist the new PID;
5. publish updated state.

This minimizes a gap in assertions.

## 8.3 `pmset disablesleep`

Preserve the existing session-scoped behavior:

- session start: `sudo pmset -a disablesleep 1`;
- session stop/quit/error rollback: `sudo pmset -a disablesleep 0`.

The controller must preserve rollback when any later startup step fails.

Recommended startup transaction:

```text
validate prerequisites configured as hard requirements
    → set disablesleep 1
    → apply Screen Lock policy
    → start assertion process
    → mark session running
```

On failure, unwind every completed step.

---

## 9. Display topology provider

## 9.1 Hot-path APIs

Use CoreGraphics and AppKit for live topology:

- `CGGetOnlineDisplayList`
- `CGDisplayIsBuiltin`
- `CGDisplayIsOnline`
- `CGDisplayIsActive`
- `CGMainDisplayID`
- `CGDisplayIsInMirrorSet` or `CGDisplayMirrorsDisplay`
- `CGDisplayBounds`
- `NSScreen.screens`
- `NSScreen.localizedName`
- `NSApplication.didChangeScreenParametersNotification`

Use the `NSScreenNumber` device-description value to map `NSScreen` metadata to `CGDirectDisplayID` when possible.

## 9.2 Avoid `system_profiler` polling

`system_profiler SPDisplaysDataType` is useful for diagnostics but too slow for the lid transition hot path. Do not call it every poll interval.

The runtime should:

- subscribe to screen-parameter change notifications;
- keep the latest topology snapshot in memory;
- refresh synchronously on the exact lid transition;
- schedule bounded follow-up samples during the settle window.

## 9.3 Stability calculation

A topology is stable when consecutive samples agree on the relevant external-display identity set for a configured interval.

Suggested configuration values:

```swift
struct DisplayTransitionConfiguration: Equatable, Sendable {
    let settleDelay: TimeInterval
    let sampleInterval: TimeInterval
    let requiredStableSamples: Int
    let missingDisplayWarningDelay: TimeInterval
}
```

Initial values for hardware testing:

- settle delay: `0.5` seconds;
- sample interval: `0.5` seconds;
- stable samples: `3`;
- missing-display warning: `5` seconds.

These are starting values, not immutable requirements. Validate them with the portable display and dummy adapter.

---

## 10. Lid transition state machine

## 10.1 Why a reducer

The safety decision must combine mode, previous topology, current topology, elapsed time, and actions already issued. Implement it as a pure reducer so race cases can be tested without physical hardware.

## 10.2 State

```swift
enum LidPhase: Equatable, Sendable {
    case open
    case settling(LidCloseContext)
    case closed(LidCloseContext)
}

struct LidCloseContext: Equatable, Sendable {
    let closedAt: Date
    let preCloseTopology: DisplayTopology
    var latestTopology: DisplayTopology
    var consecutiveNoExternalSamples: Int
    var topologyStable: Bool
    var automaticSleepEvaluated: Bool
    var automaticSleepIssued: Bool
    var wakePulseIssued: Bool
    var missingDisplayWarningIssued: Bool
}
```

## 10.3 Events

```swift
enum LidRuntimeEvent: Equatable, Sendable {
    case sessionStarted(mode: SessionMode, topology: DisplayTopology, at: Date)
    case sessionStopped(at: Date)
    case lidOpened(topology: DisplayTopology, at: Date)
    case lidClosed(topology: DisplayTopology, at: Date)
    case topologyChanged(DisplayTopology)
    case settleTimerFired(at: Date)
    case powerChanged(isOnAC: Bool, at: Date)
}
```

## 10.4 Effects

```swift
enum LidRuntimeEffect: Equatable, Sendable {
    case refreshTopology(after: TimeInterval)
    case sleepAllDisplays
    case issueWakePulse(duration: TimeInterval)
    case publishReadiness
    case notifyOnce(code: String, title: String, body: String)
    case recordEvent(DiagnosticEvent)
}
```

The runtime coordinator executes effects. The reducer never executes a command.

## 10.5 Agent Display mode rules

The reducer must enforce these invariants:

1. `sleepAllDisplays` is impossible in Agent Display mode.
2. A wake pulse can be issued at most once per lid-close context.
3. A missing-display notification can be issued at most once per configured interval/context.
4. Opening the lid resets the close context.
5. Display reconnects update readiness but do not create repeated wake loops.

Suggested behavior on `open → closed`:

```text
capture fresh topology
create LidCloseContext
publish readiness
schedule topology refreshes
if wake pulse enabled and an external display is present or reconnects:
    issue one bounded wake pulse
```

If no external display becomes stable within the warning delay:

- remain awake;
- report degraded readiness;
- notify once;
- never sleep displays automatically.

## 10.6 Standard mode rules

Automatic display sleep is allowed only if all conditions are true:

- the Standard-mode preference is enabled;
- no external display was present in the pre-close snapshot;
- no external display appeared during the settle window;
- the required number of consecutive stable samples report no external display;
- the action has not already been evaluated or issued for this closure.

Critical invariant:

> If an external display was online immediately before lid closure, do not call `pmset displaysleepnow` for that lid-close context, even if the display temporarily disappears afterward.

This single historical check eliminates the observed race.

## 10.7 Manual display sleep

Keep the manual command separate from automatic policy.

When Agent Display mode is active, the UI should label it clearly, for example:

> Sleep all displays now

and optionally require confirmation:

> This will blank the display used by computer-use agents until it is woken again.

---

## 11. Bounded wake pulse

## 11.1 Command

Use a short child process:

```bash
/usr/bin/caffeinate -u -t 5
```

## 11.2 Conditions

Issue only when all are true:

- session mode is Agent Display;
- the feature preference is enabled;
- lid just closed or a previously missing external display just reappeared;
- the current close context has not issued a wake pulse;
- an external online display is present.

## 11.3 Guardrails

- Do not retain this as the main assertion process.
- Capture exit status asynchronously.
- Apply a timeout slightly longer than the requested duration.
- Record success/failure.
- Do not retry automatically in a loop.
- If hardware testing shows the pulse itself destabilizes a display model, retain a user-facing toggle and default it appropriately.

---

## 12. Readiness computation

## 12.1 Readiness contract

Clolid should report what it can observe, not guarantee what it cannot.

### Blocking reasons

For Agent Display mode:

- session not running;
- system is not on AC power when Agent mode requires AC;
- `SleepDisabled` is not active;
- Clolid assertion process is not running;
- no external online display is present after the settle interval.

### Advisory reasons

- external display is not the Main Display;
- external keyboard is absent or unknown;
- external pointing device is absent or unknown;
- topology is still settling;
- external display is mirrored rather than independent;
- Screen Lock is set to a policy that may interrupt unattended operation;
- accessory approval cannot be confirmed;
- Computer Use capture has not been externally verified.

### Ready state

Suggested summary:

> Ready for agents

Only when:

- Agent Display mode is selected;
- session is running;
- AC power is present;
- system and assertion state are active;
- external topology is stable and contains an online display;
- no blocking reasons remain.

External keyboard and mouse detection may remain advisory if the implementation cannot classify them reliably across USB and Bluetooth transports.

## 12.2 HID detection

Investigate `IOHIDManager` / IOKit usage-page and usage values for:

- keyboard;
- mouse;
- trackpad or pointer.

Attempt to distinguish built-in from external using available properties such as built-in flags and transport. Treat uncertain classification as `unknown`, not `absent`.

Do not make release completion depend on perfect HID classification. A truthful advisory with setup instructions is preferable to a false blocking error.

## 12.3 Accessory approval

macOS does not expose a simple public API that proves every accessory is approved for closed-lid operation. Do not infer approval from charging state.

Show an instruction when readiness is degraded or detection is unknown:

> Open System Settings → Privacy & Security → Accessories and approve the display, keyboard, and mouse while the Mac is unlocked.

---

## 13. UI design

## 13.1 Popover

Add or update status rows:

- Mode
- Session
- Lid
- System awake
- Agent display
- Input devices
- Power
- Screen lock

Agent-mode header examples:

- `READY — Agent display active`
- `ATTENTION — External display missing`
- `SETTLING — Display connection changing`

Keep the summary compact. Put detailed reasons in an expandable section or Settings.

## 13.2 Mode picker

Place under **Session**:

```text
Mode                 Standard | Agent Display
```

Selecting Agent Display while a session is active should:

1. update the persisted mode;
2. restart the assertion profile safely;
3. recompute readiness;
4. not re-run Screen Lock authentication unless the policy itself changes.

## 13.3 Behavior settings

Standard mode:

- `Sleep display on lid close`
- `Lid close alert`
- `Start alert`

Agent Display mode:

- `Wake agent display on lid close`
- `Warn if agent display disconnects`
- `Require AC power` (strongly recommended)
- automatic display-sleep setting hidden or disabled with explanatory copy.

## 13.4 Diagnostics action

Add:

- `Copy diagnostics`

A later PR may add `Save diagnostics…` through `NSSavePanel`, but copy-to-clipboard is sufficient for the first implementation.

Show non-blocking progress while collecting slow sections.

## 13.5 Safety copy

Retain explicit warnings for `No lock`:

- anyone with physical access can use the active session;
- Clolid does not disable FileVault or other macOS protections;
- the setting is intended only for trusted local automation environments.

Add a thermal warning for closed-lid sessions and keep the external-power guardrail visible.

---

## 14. Diagnostics design

## 14.1 Report format

Use a versioned plain-text report:

```text
Clolid Diagnostics v1
Generated: 2026-07-17T...

[Application]
Version: ...
macOS: ...
Session mode: Agent Display
Session running: true
Session started: ...

[Readiness]
Summary: ...
Reasons: ...

[Power Assertions]
Owned caffeinate PID: ...
Owned caffeinate args: -d -i -s
SleepDisabled: 1
...

[Display Topology]
...

[Recent Events]
...

[System Commands]
pmset -g: ...
pmset -g ps: ...
pmset -g assertions: ...
ioreg lid state: ...
system_profiler displays: ...
```

## 14.2 Commands

Collect on a background queue with per-command timeouts:

```bash
pmset -g
pmset -g ps
pmset -g assertions
ioreg -r -k AppleClamshellState -d 1
system_profiler SPDisplaysDataType
pgrep -fl caffeinate
```

The normal polling path must not depend on the diagnostic commands.

## 14.3 Native event buffer

Keep an in-memory ring buffer, for example 100 events:

```swift
struct DiagnosticEvent: Equatable, Sendable {
    let at: Date
    let category: String
    let code: String
    let message: String
}
```

Record:

- session start/stop;
- mode changes;
- lid open/close;
- topology snapshots or concise diffs;
- automatic-display-sleep suppression reason;
- manual or automatic display-sleep execution;
- wake pulse execution/result;
- AC disconnect;
- assertion process start/stop/restart;
- Screen Lock policy application/result;
- errors.

## 14.4 Redaction

Do not include:

- the Mac login password;
- contents of the password prompt;
- environment variables;
- unrelated process arguments;
- authentication tokens;
- full home-directory paths when a relative description is sufficient.

The diagnostics formatter should have unit tests proving known secret placeholders are removed.

---

## 15. Lifecycle behavior

## 15.1 Startup

1. Load and migrate preferences.
2. Restore safe idle state if auto-start is disabled.
3. Subscribe to screen-parameter notifications.
4. Read initial lid, power, display, and lock state.
5. If auto-start is enabled, start through the normal authorization flow.
6. Publish readiness.

## 15.2 Session start

1. Refresh power/lid/topology.
2. Enforce configured hard requirements.
3. Set `disablesleep 1`.
4. Apply Screen Lock policy.
5. Start mode-specific assertion process.
6. Mark session running.
7. Begin lid monitoring.
8. Publish readiness and notification.

## 15.3 Session stop

1. Stop timers and transition work.
2. Terminate owned wake-pulse process if still active.
3. Terminate owned main assertion process.
4. Restore Screen Lock snapshot.
5. Set `disablesleep 0`.
6. Clear transition state and PID files.
7. Publish idle readiness.

All steps should be best-effort. One cleanup failure must not prevent later cleanup steps.

## 15.4 Application termination

Reuse the same stop transaction. Do not duplicate cleanup logic in `AppDelegate`.

## 15.5 AC power loss

When `Require AC power` is enabled:

- notify once;
- stop the session through the normal cleanup path;
- record the reason;
- do not leave `disablesleep 1` active.

When disabled:

- keep the session active;
- show a prominent warning;
- note that `caffeinate -s` applies only on AC power;
- retain `-d` and `-i` assertions as applicable.

---

## 16. Preference migration

Add keys with explicit defaults:

```text
SessionMode = standard
AgentWakePulseEnabled = true
AgentDisconnectWarningEnabled = true
```

Preserve:

```text
SleepDisplayOnLidClose
RequireExternalPower
ScreenLockPolicy
StartSessionOnLaunch
StartAtLogin
```

Migration rules:

- existing `SleepDisplayOnLidClose` applies only to Standard mode;
- Agent Display mode ignores it;
- selecting Agent Display does not delete the Standard-mode value;
- switching back restores the prior Standard preference;
- do not alter Screen Lock values during migration;
- include tests for missing, legacy, and malformed values.

---

## 17. Implementation sequence

Follow the repository guideline of one behavioral change per PR where practical.

## PR 1 — Pure policy and state-model extraction

Scope:

- add `ClolidCore` target;
- add `ClolidCoreTests` target;
- add `SessionMode`, `SessionPolicy`, topology/readiness models;
- add pure lid transition reducer with no runtime integration;
- preserve current application behavior.

Validation:

```bash
swift build
swift test
./script/build_and_run.sh --verify
```

Exit criteria:

- no user-visible behavior change;
- reducer tests cover the transient topology race;
- package and app still build.

## PR 2 — Session mode and assertion profiles

Scope:

- add persisted mode picker;
- introduce `SessionAssertionController`;
- use `-i -s` for Standard and `-d -i -s` for Agent Display;
- implement safe active-session profile restart;
- expose owned PID/args in status and diagnostics model.

Exit criteria:

- stop/quit restores `disablesleep 0`;
- only owned `caffeinate` is terminated;
- mode switching does not leave duplicate assertion processes;
- existing Screen Lock behavior remains intact.

## PR 3 — Hardened lid/display transition runtime

Scope:

- implement topology provider and screen-change notifications;
- integrate reducer;
- make Agent Display mode incapable of automatic display sleep;
- use pre-close topology and stable samples in Standard mode;
- add one bounded wake pulse;
- rate-limit warnings.

Exit criteria:

- induced transient display loss cannot produce `displaysleepnow` when a display was present before close;
- Agent mode never produces that command;
- physical monitor and dummy-plug validation completed.

## PR 4 — Readiness and diagnostics

Scope:

- compute readiness reasons;
- add optional HID detection with tri-state output;
- add diagnostics ring buffer and copy action;
- add timeout-aware background command collection;
- add redaction tests.

Exit criteria:

- readiness is truthful and stable;
- diagnostics do not block the UI;
- diagnostics contain enough information to distinguish system sleep, display loss, and AX/capture issues.

## PR 5 — UI, documentation, and release preparation

Scope:

- polish popover and Settings copy;
- update README and screenshots;
- add troubleshooting and supported setup;
- update changelog and version files only when shipping;
- package and validate release artifact.

Exit criteria:

- new user can configure the hardware and mode from documentation alone;
- release artifact launches correctly;
- all acceptance tests pass.

---

## 18. Automated test plan

## 18.1 Session policy tests

- Standard returns `[-i, -s]`.
- Agent Display returns `[-d, -i, -s]`.
- Agent Display disallows automatic display sleep.
- Agent Display supports bounded wake pulse.

## 18.2 Lid reducer tests

1. **Agent mode, external display present before close**
   - never emits `sleepAllDisplays`;
   - emits bounded refreshes;
   - emits at most one wake pulse.

2. **Agent mode, no display at close, display reconnects**
   - degraded readiness first;
   - one wake pulse after reconnect;
   - never sleeps displays.

3. **Agent mode, no display remains absent**
   - one warning after configured delay;
   - no repeated notification loop;
   - no display sleep.

4. **Standard mode, display present before close but absent in first post-close sample**
   - never sleeps displays for that close context.

5. **Standard mode, no display before close and stable absence after close**
   - emits one display-sleep effect only when preference enabled.

6. **Standard mode, display appears during settle window**
   - suppresses automatic display sleep.

7. **Lid reopens during settle window**
   - cancels pending effects;
   - resets context.

8. **Duplicate close observations**
   - no duplicate wake or sleep effects.

9. **Power loss**
   - emits stop request only when AC is required.

## 18.3 Assertion controller tests

Use a fake command/process factory:

- starts expected arguments;
- records PID;
- restart starts replacement before stopping old process;
- stop signals only owned PID;
- stale PID is ignored if process identity does not match;
- PID file is removed;
- startup failure rolls back.

## 18.4 Readiness tests

- stable external main display → ready;
- external display present but not main → advisory;
- topology settling → advisory;
- no external display → blocking;
- missing AC → blocking or advisory according to configuration;
- HID unknown → advisory, not false absence;
- assertion process missing → blocking.

## 18.5 Diagnostics tests

- report includes mode, PID, arguments, topology, and events;
- ring buffer truncates oldest entries;
- password and injected secret strings are redacted;
- command timeout produces a bounded error section;
- diagnostics collection does not mutate runtime state.

---

## 19. Manual hardware validation

## 19.1 Required hardware cases

- independently powered portable USB-C monitor;
- HDMI dummy/EDID adapter;
- direct connection to the Mac;
- connection through the user’s normal hub/dock;
- external keyboard and mouse/trackpad;
- AC adapter connected directly to the Mac when possible.

## 19.2 Required mode cases

- Standard mode, automatic display sleep off;
- Standard mode, automatic display sleep on;
- Agent Display mode, wake pulse on;
- Agent Display mode, wake pulse off;
- Screen Lock = System;
- Screen Lock = No lock in a trusted test environment;
- Start at login and auto-start session.

## 19.3 Transition cases

- close lid with stable external display;
- close lid while deliberately reconnecting the display cable;
- close lid while monitor power renegotiates;
- disconnect and reconnect external display while already closed;
- disconnect AC while closed;
- reopen lid during settle interval;
- quit Clolid while closed, then reopen;
- relaunch Clolid and restore safe state.

## 19.4 Agent validation

For each supported closed-lid case:

1. Record `pmset -g assertions`.
2. Confirm Clolid’s timer/event loop continues while the lid is closed.
3. Confirm the external/dummy display remains online in topology.
4. Confirm the physical display retains signal when applicable.
5. Launch or restart the screenshot-based agent after the agent display is online.
6. Confirm Computer Use captures a non-black desktop.
7. Run the `llm-collab` AX checks:

```bash
bin/axsend check
bin/axsend-ensure state --app Codex
```

8. Confirm the AX doorbell can still inspect or ring the supported target.
9. Stop Clolid and verify normal sleep settings are restored.

## 19.5 Test duration

Run at least one unattended soak test:

- lid closed for at least 60 minutes;
- multiple agent turns and AX doorbells;
- at least one display reconnect;
- diagnostics captured before and after;
- verify no high-CPU polling regression.

---

## 20. Acceptance checklist

### Runtime

- [ ] Agent Display mode starts `caffeinate -d -i -s`.
- [ ] Standard mode retains its intended assertion profile.
- [ ] Agent Display mode cannot automatically invoke `pmset displaysleepnow`.
- [ ] Pre-close external-display presence suppresses automatic display sleep for the full close context.
- [ ] Wake pulse is bounded to one per transition.
- [ ] Topology warnings are rate-limited.
- [ ] AC-loss behavior follows the configured policy.
- [ ] Stop and quit restore `pmset -a disablesleep 0`.
- [ ] Only Clolid-owned assertion processes are terminated.

### Readiness and UI

- [ ] Mode is visible and understandable.
- [ ] Readiness reports display, power, assertion, and input-device state without guessing.
- [ ] Contradictory display-sleep settings are unavailable in Agent Display mode.
- [ ] No-lock and thermal risks remain clearly disclosed.
- [ ] Diagnostics can be copied without freezing the UI.

### Testing

- [ ] `swift build` passes.
- [ ] `swift test` passes.
- [ ] `./script/build_and_run.sh --verify` passes.
- [ ] Portable-monitor transient-disconnect test passes.
- [ ] Dummy-plug closed-lid test passes.
- [ ] Computer Use captures a non-black desktop in the supported setup.
- [ ] AX doorbell continues to function while closed.
- [ ] 60-minute soak test passes without CPU or process leaks.

### Documentation and release

- [ ] README documents AC power, approved display, keyboard, and mouse requirements.
- [ ] README documents dummy-display and Main Display setup.
- [ ] Troubleshooting distinguishes actual system sleep from display/capture loss.
- [ ] Changelog and version files are updated at release time.
- [ ] Packaged app launches and locates its resource bundle.

---

## 21. Risks and mitigations

### Risk: `-d` increases energy use

Mitigation:

- scope it to Agent Display mode;
- recommend AC power;
- keep a visible active-session indicator;
- preserve quick stop and restore controls.

### Risk: wake pulse behaves differently across Mac/display models

Mitigation:

- one bounded pulse;
- user-visible toggle;
- diagnostics record;
- hardware validation before selecting the default.

### Risk: HID detection is unreliable

Mitigation:

- tri-state model;
- advisory rather than hard failure when unknown;
- clear setup instructions.

### Risk: moving logic creates a broad refactor

Mitigation:

- extract only pure policy and reducer code;
- keep existing SwiftUI/AppKit structure unless directly required;
- land extraction separately with no behavior change.

### Risk: automatic display sleep remains dangerous in Standard mode

Mitigation:

- require pre-close absence plus repeated stable absence;
- consider disabling the preference by default for new installations;
- retain manual sleep as the explicit escape hatch.

### Risk: session remains unlocked unattended

Mitigation:

- preserve explicit Screen Lock selection;
- warn strongly for No lock;
- never silently alter the user’s security policy;
- avoid collecting sensitive diagnostic data.

---

## 22. Documentation references

Official Apple guidance to reference from README and troubleshooting:

- External display troubleshooting and closed-lid prerequisites:  
  https://support.apple.com/102501
- Accessory approval and closed-lid accessory requirements:  
  https://support.apple.com/102282

Local implementation references:

```bash
man caffeinate
man pmset
```

Clolid must describe these requirements as supported-operating conditions, not as limitations it can bypass.

---

## 23. Codex execution instructions

1. Read issue #2 and this file before changing code.
2. Inspect the latest `main` branch; do not assume this plan’s suggested filenames already exist.
3. Preserve unrelated local changes and repository release conventions.
4. Begin with PR 1 and keep it behavior-neutral.
5. Add failing reducer tests for the transient display race before integrating runtime changes.
6. Keep shell/system calls behind narrow adapters.
7. Do not introduce a repeating wake loop.
8. Do not add broad process termination such as `pkill caffeinate`.
9. Do not use `system_profiler` in the polling hot path.
10. Treat unknown hardware/permission state honestly.
11. Run build, test, and app verification for every PR.
12. Add manual hardware evidence to the relevant PR before marking it ready.
13. Update this plan when an implementation decision changes the product or acceptance contract.
14. Link every implementation PR to issue #2.

The epic is complete only when the supported dummy-display/external-HID setup remains awake, visually capturable, and operational for both Computer Use and AX coordination with the lid closed.