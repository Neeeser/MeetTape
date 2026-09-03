# WebRTC acoustic echo cancellation, vendored

BSD-3-Clause. See `COPYING`.

## Where this came from

`https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing`, tag v2.1
(WebRTC M131), plus the abseil it requires. Both unmodified: nothing in
`webrtc/` or `absl/` is edited. The only files written here are
`pipit_aec3.cc`, `include/pipit_aec3.h` and this note.

## Why it is vendored rather than depended on

Nobody publishes this for SwiftPM. The WebRTC XCFrameworks that exist reach the
canceller only through a live `RTCPeerConnection`; none expose `ProcessStream`,
so none can be handed two recorded files. The upstream build is meson, which
this repository does not otherwise need. Source rather than a prebuilt binary,
so what CI builds is what ships.

## What was left out

Test and benchmark sources, gmock and gtest users, abseil's two code-generator
tools, which each carry their own `main`, and the x86 and MIPS kernels. The
NEON kernels are compiled, which is why `ooura_fft_neon.cc` and its tables are
present while the SSE2 ones are not.

## Taking a newer version

Copy `webrtc/` and `absl/` from the new tag, apply the exclusions above, and
run `./scripts/test.sh`. The defines live in `Package.swift`, not here. Check
the numbers in the echo tests still hold: the canceller's behaviour is measured,
not assumed.
