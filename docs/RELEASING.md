# Releasing Pipit

Pipit releases are built from version tags. The release workflow tests the
project, signs and notarizes the application, creates ZIP and DMG archives,
writes SHA-256 checksums, and drafts a GitHub release.

## Requirements

The release repository needs these GitHub Actions secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for the exported certificate |
| `APPLE_ID` | Apple ID used by the notary service |
| `APPLE_TEAM_ID` | Apple Developer team identifier |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |

The workflow falls back to ad-hoc signing when the certificate is absent. Do
not publish an ad-hoc signed build. Gatekeeper will reject it on another Mac.

## Prepare the release

Start from an up-to-date `main` branch with a clean working tree. Update
`VERSION` and run the application and extension tests:

```sh
printf '1.2.0\n' > VERSION
./scripts/test.sh
(cd extension && npm test)
git add VERSION
git commit -m "chore: release 1.2.0"
```

Push the version commit through the normal pull request process. After it lands
on `main`, create and push the matching tag:

```sh
git switch main
git pull --ff-only
git tag v1.2.0
git push origin v1.2.0
```

The tag starts `.github/workflows/release.yml`. The workflow creates these
artifacts:

```text
Pipit-1.2.0.zip
Pipit-1.2.0.dmg
Pipit-1.2.0.sha256
```

## Review the draft

The workflow creates a draft GitHub release. Before publishing it:

1. Confirm that the test, signing, notarization, and packaging steps passed.
2. Compare the ZIP and DMG checksums with `Pipit-1.2.0.sha256`.
3. Install the DMG on a Mac that did not build it.
4. Confirm that Gatekeeper accepts the application.
5. Complete setup and record a short meeting.
6. Review the generated release notes and publish the draft.

## Local release build

Use the same scripts when testing credentials locally:

```sh
PIPIT_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
  ./scripts/bundle-app.sh release

APPLE_ID="name@example.com" \
APPLE_TEAM_ID="TEAMID" \
APPLE_APP_PASSWORD="app-password" \
  ./scripts/notarize.sh dist/Pipit.app

./scripts/package.sh 1.2.0
```

`scripts/package.sh` preserves the application signature in both archives.

## Update Homebrew

After the GitHub release is public, update the `pipit` cask with the new version,
release URL, and ZIP checksum. The cask must leave `~/Documents/Pipit` intact
when it removes application support files.

Verify the published cask with:

```sh
brew update
brew install --cask pipit
brew uninstall --cask pipit
```

## Browser extension

The application bundle includes the browser sensor and native host. Firefox
distribution through addons.mozilla.org uses the extension identifier
`sensor@pipit.app`. Keep that identifier aligned with
`extension/firefox/manifest.json` when publishing an updated XPI.
