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
swift test -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -warnings-as-errors
./script/build_and_run.sh --verify
```

The interactive verification command uses a debug build. The release archive command uses `./script/build_and_run.sh --bundle` internally, which compiles the optimized Swift release configuration without launching the app.

6. Confirm normal sleep is restored when the session stops:

```bash
pmset -g | grep SleepDisabled
pgrep -fl caffeinate || true
```

7. Create the downloadable app archive:

```bash
./script/package_release.sh
/usr/bin/codesign --verify --deep --strict dist/Clolid.app
unzip -t "releases/Clolid-$(cat VERSION)-macOS.zip"
```

8. Commit the release changes and tag the commit:

```bash
version="$(tr -d '[:space:]' < VERSION)"
git tag -a "v$version" -m "Clolid $version"
git push origin main "v$version"
```

9. Create the GitHub Release and upload the archive:

```bash
version="$(tr -d '[:space:]' < VERSION)"
gh release create "v$version" "releases/Clolid-$version-macOS.zip" \
  --repo pixexid/Clolid \
  --title "Clolid $version" \
  --notes-file CHANGELOG.md
```

Every public version should have a matching GitHub Release with a downloadable `Clolid-<version>-macOS.zip` asset.

## Current Version

`0.2.0`
