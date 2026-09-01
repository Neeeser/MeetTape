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
| `AMO_JWT_ISSUER` | Mozilla add-on API key, from the AMO credentials page |
| `AMO_JWT_SECRET` | Mozilla add-on API secret for the same key |

The workflow falls back to ad-hoc signing when the certificate is absent. Do
not publish an ad-hoc signed build. Gatekeeper will reject it on another Mac.

The AMO credentials come from
<https://addons.mozilla.org/en-US/developers/addon/api/key/>. A release without
them ships an app that has no signed add-on, and Firefox users then load a
temporary add-on that Firefox drops when it quits.

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

Release Firefox installs a signed add-on permanently and refuses an unsigned
one, so the release workflow signs the extension before assembling the app:

```sh
AMO_JWT_ISSUER=... AMO_JWT_SECRET=... ./scripts/sign-extension.sh 1.2.0
```

The channel is `unlisted`, so Mozilla signs the file and returns it rather than
publishing it on addons.mozilla.org. The signed XPI lands at
`extension/signed/pipit-sensor.xpi`, and `scripts/bundle-app.sh` copies it into
the app bundle, where Settings offers it as a one-click install.

The version argument stamps the built manifest, because AMO refuses a version
it has already signed for this add-on. Pass the release version so each tag
signs a version of its own. Mozilla reviews self-distributed add-ons after the
fact and can disable one that breaks their policies.
