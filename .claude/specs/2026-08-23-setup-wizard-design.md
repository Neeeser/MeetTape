# Setup wizard redesign

Date: 2026-08-23

Replaces the single scrolling `OnboardingView` with a stepped wizard that asks
one thing per screen, gates on the permissions MeetTape cannot work without,
and updates itself the moment a permission is granted instead of asking for a
relaunch.

## Why

The current first-run screen is one long scroll of six cards. Every card is
optional in practice, nothing is gated, and a user can press Done having
granted nothing, so the first meeting fails somewhere in the pipeline. Two
further defects:

- The System Settings deep links use the pre-Ventura pane identifiers
  (`com.apple.preference.security`). The shipping target is macOS 27.
- Screen recording state is read through `CGPreflightScreenCaptureAccess()`,
  which caches per process, so granting it while MeetTape runs does not show up
  until the next launch.

Reference for the shape: Jump Desktop Connect's permissions assistant. One
window, an intro page, one page per permission, each with a picture of the
exact System Settings row to switch on, a live "Waiting for …" line, and a
Continue that stays disabled until the permission is actually in effect.

## Steps

A step is a value in `MeetTapeCore`. It carries an identity, whether it is
required, and a predicate over `AppSettings`, permission states, local model
state and native messaging host status. `SetupFlow` assembles the list, reports
the first unsatisfied step, and reports whether setup can finish. It performs no
I/O and is tested directly.

| # | Step | Required | Satisfied when |
|---|---|---|---|
| 1 | Welcome | no | Continue pressed |
| 2 | Where it runs | yes | Local chosen, or Cloud chosen and the key verified |
| 3 | Speech models | yes | every unit in `LocalModelUnit.required(for:)` is on disk, or a download is running |
| 4 | Microphone | yes | `AVCaptureDevice.authorizationStatus(for: .audio) == .authorized` |
| 5 | Screen recording | yes | the live window-name probe passes |
| 6 | Accessibility | yes | `AXIsProcessTrusted()` |
| 7 | Calendar and notifications | no | never blocks |
| 8 | Firefox | no | never blocks |
| 9 | Finish | no | Done pressed |

`PermissionKind.isRequired` becomes `true` for `screenRecording` and
`accessibility`. Microphone was already required.

### Gating and reappearance

`AppSettings.hasCompletedOnboarding` is written only when Finish is pressed, and
Finish is unreachable while a required step is unsatisfied. So the wizard
returns on every launch until the user has been through it once.

It also returns afterwards whenever one of the three required permissions is
missing. `SetupFlow.shouldOpenAtLaunch` is the whole rule: never finished, or a
required permission not granted.

This was specified the other way first, on the grounds that reopening would be
nagging and the Permissions tab already reports it. That is wrong for a
recorder. Losing the microphone grant does not degrade MeetTape, it makes the
next meeting record nothing, and the menu bar icon looks exactly the same as it
always does. macOS drops these grants on its own after an OS update or a
re-signed build, so it reaches people who never touched a setting.

Only permissions reopen it. A model deleted from disk or a key that stopped
working are repaired in Settings and cost no recording.

A user who has finished setup before opens on the permission that broke rather
than on Welcome, so repairing one revoked grant is one screen instead of nine.

### Resumption

Nothing about position is persisted. The wizard opens on Finish when every
required step is already satisfied, and on Welcome otherwise. Walking forward
from Welcome is cheap on a reinstall because each satisfied step shows as done
with Continue already live, and the rail shows the ticks. That is also what
makes "check whether it is already downloaded" fall out for free:
`LocalModelStore` already reports per-unit presence.

Opening on the first unsatisfied step was rejected: on a fresh install the
backend step is satisfied by the `local` default, so the wizard would skip past
the local-or-cloud choice without ever showing it.

### Downloads do not block

Step 3 enables Continue as soon as a download is under way, and the step rail
carries its progress across steps 4 to 9. Only Finish waits, and it offers
"Start recording anyway" because the pipeline already queues meetings that
finish before the models arrive.

The cloud path downloads too, and says so. `LocalModelUnit.required(for:)`
always includes the 21 MB diarizer because voice memory embeds a cloud
diarizer's intervals with local models, and the default cloud transcription
model `gpt-transcribe` returns no timings, so it also requires the 600 MB CTC
aligner. Step 3 states both figures and what each unit does before anything
starts.

### The cloud key

Continue on step 2 requires a key that has answered a real request, through the
existing `OpenAIClient.verifyCredentials`. When the request fails for a reason
that is not a rejected key, the step offers "Continue anyway" so a setup done
offline is not a dead end.

## Live permission detection

`PermissionObserver` in `MeetTapeIntegrations` publishes a fresh
`[PermissionStatus]` whenever anything might have changed. Three sources:

- `DistributedNotificationCenter` on `com.apple.accessibility.api`, which the
  system posts when the Accessibility list changes.
- `NSWorkspace.didActivateApplicationNotification`, which fires when the user
  switches back from System Settings.
- A 1.5 s timer, running only while the wizard window is visible.

The observer takes its notification centres as parameters so a test can drive a
grant through it.

### Screen recording

`CGPreflightScreenCaptureAccess()` stays the primary check. It is the supported
call, and it is asked first.

It has a long history of answering from a cache filled once per process, which
is what makes applications ask for a relaunch after a grant. A fallback covers
that: `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`
and look for a `kCGWindowName` on an ordinary window owned by another process,
which the window server populates only for a process holding the grant. It runs
only when the preflight call says no, so it costs nothing when the preflight
call is right.

The fallback has to be conservative, because a false positive lets setup finish
on a machine that cannot read a window title, which is the failure the gating
exists to prevent. Two filters, both load-bearing: another process, and window
layer 0. The window server's own `Menubar` window sits at layer 24 and reports
its name to every process regardless of the grant, so accepting any named window
reports the permission on every machine.

Chromium and mac-screen-capture-permissions are widely cited for this technique.
Checking their current sources, both used it once and both now call
`CGPreflightScreenCaptureAccess()` and nothing else. That is why it is a
fallback here and not the answer.

### Pane names on macOS 27

Checked by opening each anchor rather than from memory. Screen recording is
still its own pane, headed "Screen & System Audio Recording" with the caption
this spec quotes. Accessibility has moved: `Privacy_Accessibility` opens a pane
now headed **Device Control and Data Access**, covering keyboard monitoring,
mail, contacts and screen recording alongside application control. The
Accessibility item still in the System Settings sidebar is the unrelated one
holding VoiceOver and Zoom, so an illustration named after it would send people
somewhere with no MeetTape row in it.

System Settings also writes the bundle's file name in these lists, extension
included, so the illustrated row reads "MeetTape.app" and not "MeetTape".

### Deep links

`PermissionKind.settingsURL` moves to the current pane identifier:

```
x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone
x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture
x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility
x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars
x-apple.systempreferences:com.apple.settings.Notifications
```

### Granted but not effective

`PermissionState.grantedButNotEffective` stays. It is what an unsigned rebuild
produces: the toggle reads on, the running binary has no access. The step shows
the remove-and-re-add instruction rather than the plain one, because that is the
only fix.

## Window behaviour

The setup window is an ordinary window at an ordinary level, and solves being
lost in two ways that do not involve a window level:

- It asks for focus back when a permission prompt closes. MeetTape is an
  accessory application with no Dock presence, so dismissing a prompt returns
  focus to whatever was in front before it opened, and the wizard sinks with no
  Dock icon to bring it back.
- It steps aside when System Settings comes forward, moving to whichever side of
  that window has more room, so the instructions sit beside the pane they are
  about rather than behind it. The System Settings frame is read from the window
  list, since setup runs before Accessibility is granted and window bounds need
  no permission. Retried at 0.3, 0.8, 1.5 and 2.5 seconds, because System
  Settings has no window when the activation notification arrives and measured
  just over a second to put one up.

A floating level was tried for this and reverted. It fixed the sinking and put
the wizard above macOS's own permission prompts, which is the one thing that
must never be covered: a dialog the user cannot see is a dialog they cannot
answer. Staying out of the system's way beats staying in front of it.

## Guidance illustration

`SettingsPaneIllustration` is a SwiftUI view taking a pane title, the pane's own
explanatory line, and a control style. It draws MeetTape's real
`NSApp.applicationIconImage` and name in the row and rings the control in red.
One view serves all four permission panes.

Drawn rather than bundled as screenshots, for three reasons: it shows the
application's own icon and name, it follows light and dark appearance, and it
cannot go stale. Jump Desktop Connect ships a Mojave-era screenshot in
`Resources/accessibility@2x.png` that its own wizard no longer uses.

MeetTape's bundle can be dragged straight into the Accessibility and Screen
Recording lists, which accept a dropped `.app`. Both the illustrated row and the
chip beside the button are drag sources: the row is what looks like the thing
that belongs in the list, so it is what people reach for first. Neither appears
on the steps granted by a system prompt, which have no list to drop onto.

The item is built with `NSItemProvider(object: url as NSURL)`, which registers
`public.url` and `public.file-url`. `NSItemProvider(contentsOf:)` was tried
first and produced a drag that picked up, dropped and did nothing: it wants a
readable file and an application is a directory. A test pins the registered type
identifiers, since the failure is silent and looks like a dead control.

macOS adds a dropped application to these lists switched **off**, and nothing in
the API changes that. So the illustration is captioned "Drag MeetTape into the
list, then switch it on", and the red ring stays on the switch: the drop is one
of two steps, not the whole job.

The illustration shows the state being asked for, not the state that exists. A
user who has just removed MeetTape from the real list sees a picture that still
contains it, which reads as a live view of the pane and is wrong. The caption
above it is what makes it an instruction rather than a mirror.

## Code

New:

- `Sources/MeetTapeCore/Setup/SetupFlow.swift`
- `Sources/MeetTapeIntegrations/PermissionObserver.swift`
- `Sources/MeetTapeUI/Setup/SetupWizardView.swift`
- `Sources/MeetTapeUI/Setup/SetupStepViews.swift`
- `Sources/MeetTapeUI/Setup/SettingsPaneIllustration.swift`
- `Sources/MeetTapeUI/Setup/SetupModel.swift`

Changed:

- `PermissionsService.swift`: required set, deep links, live screen recording
  probe.
- `WindowManager.swift`: `showOnboarding` becomes `showSetup`.
- `MenuBarController.swift`: a `Setup…` item, which does not exist today.
- `Components.swift`: `PermissionRow` moves here, since `PermissionsSettingsTab`
  still uses it.

Deleted:

- `Sources/MeetTapeUI/OnboardingView.swift`
- `OnboardingModel` in `ViewModels.swift`

## Tests

`SetupFlowTests`, registered in `Sources/MeetTapeTests/main.swift`:

- a required step that is unsatisfied keeps setup from finishing
- Cloud without a verified key does not satisfy step 2; Local does
- the required model unit set differs between the local and cloud paths
- models already on disk satisfy step 3 without starting a download
- the wizard resumes on the first unsatisfied step

`PermissionObserver` is driven through an injected notification centre: one
refresh per signal, no refresh after teardown.

The screen recording probe depends on real TCC state, so its test is gated
behind `MEETTAPE_LIVE_CAPTURE` alongside the existing live capture suite.

## Copy

Each step states the mechanism and what is lost without it. Accessibility reads:
"MeetTape reads Slack's window contents to see when a huddle starts and ends. It
reads nothing else, and it never sends what it reads anywhere."

Optional steps keep their primary action in the accent colour and render Skip as
plain secondary text, so skipping is available without being invited.
