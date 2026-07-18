# Clolid

<p align="center">
  <img src="docs/assets/clolid-app-icon.png" alt="Clolid app icon" width="128">
</p>

Clolid is a lightweight macOS menu bar app for closed-lid desk and unattended-agent setups. It keeps the Mac awake while the lid is closed, observes the live display topology, and applies a mode-specific display policy.

The app is intentionally small: it wraps the system power tools needed for this workflow instead of trying to replace a full power-management utility.

<p align="center">
  <img src="docs/assets/clolid-menu.jpeg" alt="Clolid menu bar popover" width="358">
</p>

## Features

- Start and stop a closed-lid awake session from the menu bar.
- Run `pmset disablesleep` only for the active session.
- Choose Standard mode for the existing closed-lid workflow or Agent Display mode for unattended computer-use agents.
- Keep the system awake with a mode-specific `caffeinate` assertion.
- Stabilize CoreGraphics display-topology changes before deciding whether to sleep displays.
- Wake a connected Agent Display with a separate five-second user-activity pulse.
- Verify external keyboards and pointing devices from IOKit HID metadata.
- Report Agent Display readiness with blocking conditions and honest advisories.
- Optional notifications for session start and lid-close display sleep.
- Optional start-at-login LaunchAgent.
- Settings for external-power requirement, polling interval, and menu-bar icon style.
- Optional session-scoped Screen Lock policy using macOS `sysadminctl`.

## Requirements

- macOS 13 or newer.
- Xcode command line tools.
- Administrator permission when starting or stopping a session, because Clolid changes `pmset disablesleep`.

## Download

Download the latest `Clolid-*-macOS.zip` from the [GitHub Releases page](https://github.com/pixexid/Clolid/releases). Unzip it and move `Clolid.app` to `/Applications`.

The app is currently distributed as an unsigned open-source build. On first launch, macOS may require opening it from Finder with Control-click -> Open.

## Build

```bash
swift build
```

## Run Locally

```bash
./script/build_and_run.sh
```

The script builds the SwiftPM executable, creates `dist/Clolid.app`, copies the app resources, and opens the app.

For a quick launch check:

```bash
./script/build_and_run.sh --verify
```

## Package a Release Build

```bash
./script/package_release.sh
```

The package script creates `dist/Clolid.app` and `releases/Clolid-<version>-macOS.zip` without launching the app. Attach that zip to the matching GitHub Release.

## How It Works

When a session starts, Clolid enables `disablesleep` and launches one owned assertion process:

```bash
sudo pmset -a disablesleep 1
```

Standard mode uses:

```bash
caffeinate -i -s
```

Agent Display mode uses:

```bash
caffeinate -d -i -s
```

Agent Display mode prevents automatic display sleep. Changing modes during an active session starts the replacement assertion before stopping the previous Clolid-owned process.

While the session is running, Clolid reads `AppleClamshellState` and captures CoreGraphics topology snapshots. A display-reconfiguration callback triggers a fresh snapshot, while the normal lid poll remains the fallback.

In Standard mode, a closed-lid transition must produce three time-spaced topology samples with no external display before Clolid runs:

```bash
pmset displaysleepnow
```

The pre-close topology remains authoritative for the whole transition. A transient disconnect cannot authorize display sleep if an external display was present before or during the lid-close change.

In Agent Display mode, Clolid never runs the automatic display-sleep command. When an external display is available at lid close, Clolid launches a separate, self-expiring wake pulse and renews it once after the closed-lid topology stabilizes. When a display first reconnects during settling, Clolid launches one pulse:

```bash
caffeinate -u -t 5
```

The manual display-sleep command remains available in both modes and sleeps all displays.

Agent Display readiness checks the session, `disablesleep`, the long-lived assertion, external-display activity, topology stability, power source, external input devices, and Screen Lock status. Clolid recognizes physical USB and Bluetooth keyboards, mice, and trackpads from static IOKit HID metadata without opening the devices or capturing input. A confirmed missing device blocks readiness. Incomplete metadata, unsupported transports, or IOKit enumeration failures remain advisories rather than being silently reported as present or absent.

Clolid can also apply a session-scoped Screen Lock policy using `sysadminctl -screenLock`, which is the source that matches macOS Lock Screen settings on current macOS releases. The app asks for your Mac login password in a Clolid-styled prompt when a non-System Screen Lock policy is applied during a session, passes it to macOS for that command, and does not store it.

Use `System` to leave the setting untouched. Use `No lock` only for trusted long-running local automation sessions where you accept that the user session stays unlocked while the display is off.

When the session stops, Clolid terminates only its owned `caffeinate` process and restores:

```bash
sudo pmset -a disablesleep 0
```

Crash recovery verifies the saved PID, exact executable path, and process start identity before signaling a stale assertion, preventing a reused PID from being treated as Clolid-owned.

## Safety Notes

Clolid is designed for setups with external power and, usually, an external display. If the Mac is closed in a bag or poorly ventilated space while a session is active, it can continue running and generate heat. Use the external-power requirement if you want an additional guardrail.

If you ever need to restore normal sleep manually:

```bash
sudo pmset -a disablesleep 0
```

Quit Clolid to terminate the assertion process it owns. Avoid `pkill caffeinate`, which can terminate unrelated processes started by other apps or shell sessions.

If Screen Lock was changed outside Clolid, configure “Require password after screen saver begins or display is turned off” in System Settings or check the effective value with `sysadminctl -screenLock status`.

## Project Layout

```text
Package.swift
Sources/Clolid/main.swift
Sources/Clolid/Resources/
Sources/ClolidCore/
Sources/ClolidRuntime/
Tests/ClolidCoreTests/
Tests/ClolidRuntimeTests/
script/build_and_run.sh
```

## Versioning

Clolid follows Semantic Versioning. See [VERSIONING.md](VERSIONING.md).

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Clolid is released under the MIT License. See [LICENSE](LICENSE).
