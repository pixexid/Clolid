# Changelog

All notable changes to Clolid will be documented in this file.

This project follows Semantic Versioning.

## 0.1.3 - 2026-06-10

- Fixed a menu-bar status refresh loop that could drive high CPU use during long-running sessions.
- Avoided sleeping the external display on lid-close when a clamshell display is already online.

## 0.1.2 - 2026-05-19

- Reduced idle resource use by removing continuous shell-backed status polling while the menu is closed.
- Reduced active-session polling to lid-state checks, with slower power-source and display-detail refreshes.
- Removed the `caffeinate -u` user-active assertion to avoid unnecessary display/user-activity pressure.
- Replaced active lid polling with native IOKit reads and clamped invalid poll interval values.

## 0.1.1 - 2026-05-17

- Constrained the menu to avoid screen-edge overflow.
- Removed experimental Screen Lock automation after confirming macOS 26 does not reliably honor plist edits for the Lock Screen setting.
- Reintroduced Screen Lock control through authenticated `sysadminctl -screenLock`, the source that matches macOS Lock Screen settings.
- Applied Screen Lock policy changes immediately during active sessions and replaced the generic password dialog with a native Clolid prompt.
- Added password prompt feedback states for typing, applying, success, and failure.
- Closed the menu when clicking outside the popover.

## 0.1.0 - 2026-05-15

- Initial open-source baseline.
- Added menu-bar closed-lid awake session control.
- Added display sleep trigger for lid-close events.
- Added settings, notifications, login item support, and About/Welcome windows.
- Added Clolid app icon and menu-bar state icons.
- Added GitHub Release packaging for downloadable app builds.
