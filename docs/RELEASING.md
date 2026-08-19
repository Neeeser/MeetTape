# Releasing MeetTape

A release is produced by pushing a version tag. `.github/workflows/release.yml`
builds the project, runs the test suite, packages a zip and a dmg with checksums,
and drafts a GitHub release.

```
tag vX.Y.Z
   ↓
clean build + tests
   ↓
Developer ID signature        (skipped without secrets)
   ↓
notarize + staple             (skipped without secrets)
   ↓
zip + dmg + SHA-256
   ↓
draft GitHub Release
   ↓
Homebrew cask update          (not wired up yet)
```

## Cutting a release

```bash
echo "1.2.0" > VERSION
git commit -am "chore: 1.2.0"
git tag v1.2.0
git push origin main --tags
```

The workflow drafts the release instead of publishing it, so the artifacts can be
checked before they become downloadable.

## What is still missing

The remaining work is administrative. The pipeline already contains these steps
and skips them while the credentials are absent.

### Apple Developer Program

A paid membership ($99/year) and a **Developer ID Application** certificate.
Without them the build is ad-hoc signed, which has three consequences:

- Gatekeeper refuses to open the application normally on another Mac.
- TCC pins its grants to the code hash, so every rebuild invalidates Microphone,
  Accessibility and Screen Recording. A Developer ID signature keeps a stable
  designated requirement and the grants survive updates.
- Actionable notifications are refused under an ad-hoc signature
  (`UNErrorDomain Code=1`), so the "Keep recording?" buttons work only on a
  signed build.

### Repository secrets to add

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | base64 of the exported `.p12` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | password used on export |
| `APPLE_ID` | Apple ID for the notary service |
| `APPLE_TEAM_ID` | ten-character team identifier |
| `APPLE_APP_SPECIFIC_PASSWORD` | app-specific password, not the account password |

Export the certificate with:

```bash
security find-identity -v -p codesigning          # confirm it is installed
# Keychain Access → export the "Developer ID Application" identity as .p12
base64 -i DeveloperID.p12 | pbcopy
```

Then the same build runs signed with no workflow changes:

```bash
MEETTAPE_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
  ./scripts/bundle-app.sh release
APPLE_ID=… APPLE_TEAM_ID=… APPLE_APP_PASSWORD=… \
  ./scripts/notarize.sh dist/MeetTape.app
```

Notarization accounts for most of the wall-clock time; a full pipeline usually
takes 10 to 15 minutes.

### Homebrew

Not published yet. Two constraints apply:

- Casks without signing and notarization are deprecated and are removed from the
  official tap, so notarization is effectively mandatory rather than optional.
- Since Homebrew 6.0.0 non-official taps must be trusted per machine, which adds
  a step to the custom-tap route.

The intended path is a project-owned tap first, then homebrew-cask once the app
is stable and notarized:

```ruby
cask "meettape" do
  version "1.2.0"
  sha256 "…"                      # from MeetTape-1.2.0.sha256
  url "https://github.com/Neeeser/MeetTape/releases/download/v#{version}/MeetTape-#{version}.zip"
  name "MeetTape"
  desc "Automatic meeting recorder, transcriber and archive"
  homepage "https://github.com/Neeeser/MeetTape"
  depends_on macos: ">= :sequoia"
  app "MeetTape.app"
  zap trash: [
    "~/Library/Application Support/MeetTape",
    "~/Library/Application Support/Mozilla/NativeMessagingHosts/com.meettape.sensor.json",
  ]
end
```

The `zap` stanza leaves `~/Documents/MeetTape` in place, because uninstalling the
application must not delete recordings.

### Firefox extension distribution

The extension is loaded as a temporary add-on during development. Publishing it
on addons.mozilla.org requires a Mozilla account and a signed XPI, and the
`browser_specific_settings.gecko.id` in `extension/firefox/manifest.json`
(`sensor@meettape.app`) has to match the listing.

## Before the first public release

Several acceptance criteria from the specification are still unmet:

- a genuine two-hour capture soak;
- a 30-minute-plus Slack Huddle;
- a real meeting over an hour through the chunked pipeline;
- Gatekeeper acceptance of a signed, notarized build on a clean Mac;
- native messaging verified from the packaged app rather than the build tree.

`docs/VERIFICATION.md` records what has been exercised and what has not.
