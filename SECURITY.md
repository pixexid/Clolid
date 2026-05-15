# Security

Clolid changes macOS power settings while a session is active. Treat reports that affect privilege prompts, cleanup of `pmset disablesleep`, or unexpected background execution as security-sensitive.

## Supported Versions

Only the latest released version receives security fixes.

## Reporting a Vulnerability

Open a private report through GitHub Security Advisories if the repository is hosted on GitHub. If that is not available yet, avoid posting exploit details publicly; open a minimal issue that says a security report is available and include a safe contact path.

Useful details:

- macOS version and Mac model.
- Clolid version.
- Exact steps to reproduce.
- Output from:

```bash
pmset -g
pgrep -fl caffeinate
launchctl print gui/$(id -u)/com.pixexid.Clolid.login 2>/dev/null
```

## Safety-Critical Behavior

Security and reliability fixes should preserve these invariants:

- Stopping a session restores `sudo pmset -a disablesleep 0`.
- Clolid only terminates the `caffeinate` process it started.
- Login item setup must not create duplicate menu-bar app instances.
- The app should not hide failures to restore normal sleep behavior.
