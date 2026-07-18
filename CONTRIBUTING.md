# Contributing

Thanks for helping improve Clolid. Keep changes small, testable, and focused on the closed-lid awake workflow.

## Development Setup

```bash
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
./script/build_and_run.sh --verify
```

## Pull Request Guidelines

- Keep one behavioral change per pull request.
- Update `README.md` when user-facing behavior changes.
- Update `VERSIONING.md` only when the release process changes.
- Run the warnings-as-errors test and release-build commands before opening a pull request.
- For UI changes, run `./script/build_and_run.sh --verify` and check the menu-bar app manually.
- For packaging changes, run `./script/package_release.sh` and verify the app bundle with `codesign --verify --deep --strict dist/Clolid.app`.

## Code Guidelines

- Prefer native SwiftUI and AppKit APIs over dependencies.
- Keep copy short enough for the menu bar popover.
- Avoid broad refactors when fixing a narrow bug.
- Preserve the safe stop path: stopping a session must restore `pmset disablesleep 0` and clean up Clolid's own `caffeinate` process.

## Reporting Bugs

Include:

- macOS version and Mac model.
- Whether an external display and external power were connected.
- What Clolid showed in the menu.
- Relevant output from:

```bash
pmset -g
ioreg -r -k AppleClamshellState -d 1
pgrep -fl caffeinate
```
