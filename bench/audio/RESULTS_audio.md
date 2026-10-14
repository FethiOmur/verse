# P0-C results: remote-audio capture probe (Brave)

Date: 2026-10-14, macOS 26.6.2 (25G83), Swift 6.4 toolchain, Brave 1.96.59 (Chromium 154).
Probe: `bench/audio` Swift package `TapProbe` (CLI, no window). Numbers only; no audio was written.
Output device: AirPods (the owner's choice), so the aggregate device holds the tap only, with no output sub-device.
YouTube player volume about 5 %, not muted.

## Verdict

**Core Audio process taps work for Brave.** A mono mixdown tap on Brave's Core Audio process objects, behind a
private aggregate device that contains only the tap, delivers Brave's audio and nothing from other apps.
ScreenCaptureKit was not needed and was not run.

## Results per test case

| Test | Result | Numbers | Raw file |
|---|---|---|---|
| list_targets | done | 31 Brave OS processes (1 main, 5 Helper, 24 Renderer, 1 crashpad). 3 registered with Core Audio: pid 48344 + 48346 `com.brave.Browser.helper`, pid 48284 `com.brave.Browser`. Only **helper 48344** had output running while playing. | `results/audio-20261014-024633.json` |
| tap_brave (20 s, playing) | **pass** | 199 windows of 100 ms, all with data. **84.9 %** above −60 dBFS (threshold ≥ 80 %). RMS p10/p50/p90 = −71.0 / −22.2 / −15.2 dBFS, peak −1.9 dBFS. No all-zero windows (lowest −92.8 dBFS, the gaps between words). First callback 22 ms after start; delivery delay p50/p90 = 32.0 / 32.0 ms (512-frame buffers at 48 kHz). Above-floor fraction at other floors: −50 → 81 %, −70 → 89 %, −80 → 93 %. | `results/audio-20261014-024633.json` |
| isolation (12 s, `afplay Glass.aiff` ×4) | **pass** | Control tap (global, excluding Brave) heard every chime at −22 dBFS, with exact digital zeros between chimes. The Brave tap showed no chime pattern: −25.6 dBFS during chimes vs −20.8 outside, which is just speech varying. 10 ms envelope correlation, Brave tap vs control: **−0.068**. | `results/audio-20261014-024652.json` |
| mic_bleed | skipped | Headphones (AirPods) were the output, so there is no speaker bleed to measure. Rerun later on speakers: `TapProbe --test mic_bleed --label playing`. | – |
| silence while paused (pause_watch) | skipped | Skipped for time (the owner's short-run request). Indirect evidence: a tap with no audio delivers exact zeros (the control tap between chimes). Rerun: `TapProbe --test pause_watch`, then pause playback. | – |
| fallback_sck | not run | The tap worked, so the fallback wasn't needed. Code is in place: `TapProbe --test sck` (needs Screen Recording permission). | – |

## Findings for P1-3

- **The audio comes from a single utility helper** (`Brave Browser Helper`, bundle `com.brave.Browser.helper`). It
  is not the main process and not a renderer. Tapping every Brave process object that Core Audio has registered
  covers it.
- **Matching by path misses the main process.** Chromium runs the main process from a code-sign clone
  (`/private/var/folders/…/com.brave.Browser.code_sign_clone/…/Brave Browser.app.bundle/…`). Matching processes by
  the path `/Applications/Brave Browser.app/` misses it. Match by bundle ID instead (`com.brave.Browser*`), or by
  both path forms.
- **A tap built from a list of PIDs is a snapshot.** A helper that registers after the tap starts (for example, the
  audio service restarting) is not covered. The macOS 26 `CATapDescription.bundleIDs` plus `processRestoreEnabled`
  route should fix this, but it was **not tested** (`--route bundle`).
- **No output device in the aggregate.** The aggregate holds the tap only, with no output sub-device. This worked
  with AirPods as output and avoids opening the AirPods mic, which would switch them to headset mode.
- **Silence is exact zeros.** A silent tap delivers exact zeros. A denied permission also gives zeros, so a real
  app must tell the two apart (check the permission status, and warn on long stretches of zeros while the
  meeting app has output running: `kAudioProcessPropertyIsRunningOutput`).
- **Delay is small.** About 32 ms from sample capture to delivery, with the first callback after 22 ms. Small
  next to the latency budget.

## Permission (unconfirmed)

- TCC preflight for `kTCCServiceAudioCapture` said `not_determined` before and after the run.
  `TCCAccessRequest` returned "denied" at once, yet the tap still delivered real audio. In this CLI context
  (responsible app: Claude Code's `claude.app`) the capture worked without a recorded grant. I could not confirm
  whether a dialog appeared on screen. The bundled Verse app should still declare `NSAudioCaptureUsageDescription`
  and expect the "System Audio Recording Only" prompt (System Settings → Privacy & Security → Screen & System
  Audio Recording).
- RMS p50 is −22 dBFS even though the player volume was about 5 %. Either the tap reads the signal before the
  YouTube player volume is applied, or the slider was higher than reported. Unconfirmed.

## How to rerun

```
cd bench/audio
swift run -c release TapProbe --app "Brave Browser" --seconds 20 --label playing   # list + tap (acceptance)
.build/release/TapProbe --test isolation
.build/release/TapProbe --test mic_bleed --label playing                           # speakers on
.build/release/TapProbe --test pause_watch                                          # pause during the run
```

## Permission note (main session, 2026-10-14)
Alex confirmed that **no macOS dialog appeared** during the tap run. The audio-capture request returned "denied"
and TCC stayed `not_determined`, yet the tap delivered real audio. The JSON also shows
`screenRecordingPreflight: true` for the responsible app (claude.app). Likely explanation, **unconfirmed**: an
existing Screen & System Audio Recording grant on the responsible app covers process taps. For P1-3: the Verse app
must declare `NSAudioCaptureUsageDescription`, test permission on a clean app identity (its own bundle ID, no prior
grant), and tell "no permission" from "silence" using TCC status plus `isRunningOutput`.
