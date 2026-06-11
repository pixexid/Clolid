# Versioning

Clolid uses Semantic Versioning:

```text
MAJOR.MINOR.PATCH
```

## Version Meaning

- `MAJOR`: incompatible changes to behavior, settings storage, packaging, or supported macOS versions.
- `MINOR`: new user-facing functionality that is backward compatible.
- `PATCH`: bug fixes, copy edits, icon updates, and internal improvements that do not change behavior.

Before the first stable `1.0.0` release, minor versions may still include product-shaping changes.

## Release Checklist

1. Update `VERSION`.
2. Update `AppConstants.marketingVersion` in `Sources/Clolid/main.swift`.
3. Update `APP_VERSION` and increment `APP_BUILD` in `script/build_and_run.sh`.
4. Add an entry to `CHANGELOG.md`.
5. Run:

```bash
swift build
./script/build_and_run.sh --verify
```

The release archive command uses `./script/build_and_run.sh --bundle` internally so packaging does not launch the app.

6. Confirm normal sleep is restored when the session stops:

```bash
pmset -g | grep SleepDisabled
pgrep -fl caffeinate || true
```

7. Create the downloadable app archive:

```bash
./script/package_release.sh
```

8. Commit the release changes and tag the commit:

```bash
git tag v0.1.2
```

9. Create the GitHub Release and upload the archive:

```bash
gh release create v0.1.2 releases/Clolid-0.1.2-macOS.zip \
  --repo pixexid/Clolid \
  --title "Clolid 0.1.2" \
  --notes-file CHANGELOG.md
```

Every public version should have a matching GitHub Release with a downloadable `Clolid-<version>-macOS.zip` asset.

## Current Version

`0.1.3`
