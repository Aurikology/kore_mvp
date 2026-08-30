# KORE

The digital dashboard for your mind. KORE monitors cognitive load, predicts
focus crashes, and guides a short reset — a behavioural alternative to
nicotine and stimulants for managing academic strain.

## Status

**Working prototype on Windows and Android, simulated signal.** The app
builds and runs on both, computes a real Cognitive Load Index from a real DSP
pipeline, and closes the detect → reset loop. There is no hardware yet: the EEG
stream is synthetic. **The signal processing is genuine; only the electrode is
simulated.**

| Area | State |
|---|---|
| DSP pipeline (filtering, band power, index) | Implemented, unit-tested |
| Measured sample rate, end to end | Implemented; filters and every frame-counted duration follow the device's real crystal, including one that cannot be reported until the link has streamed |
| Live dashboard (gauge, trend, reset protocol) | Implemented |
| Windows desktop build | Working |
| Android build | Working, with the native DSP cross-compiled |
| First run: welcome, pairing, contact check | Implemented |
| Session history | Implemented |
| Simulated EEG source | Implemented, with the link and every fault it can have |
| Native C++/FFI DSP path | Implemented on Windows and Android; parity-tested against Dart at 256 Hz and off-nominal |
| Suspend and resume | Implemented; a gap is refused, never spliced |
| BLE / real hardware | Both halves written - Dart tested against a fake channel, Kotlin host compiled into the APK. Off by default (`kAndroidBleHostInstalled`), because an Android build is still the simulated prototype until there is a patch to find. Nothing has talked to a radio |
| Notification tier, screen-wake | Implemented on Android, over an in-repo platform channel |
| Post-reset check-in, streaks, persistence | Implemented, on-disk, no plugins |

## Running it

```bash
flutter run -d windows
flutter run -d <android device>
```

No Developer Mode or network connection required — the project has zero
plugins and bundles its fonts. It is not plugin-free by accident: the one piece
of platform code it does have (below) is an in-repo `MethodChannel`, which adds
nothing to `pubspec.yaml` and nothing a host-VM test has to load. The Android build needs an SDK and, for the
native DSP, an NDK; without the NDK it still builds and falls back to the Dart
engine.

```bash
flutter test                   # 361 tests, including the DSP assertions
dart run tool/cli_probe.dart   # sweep load levels and print the index curve
```

## How it works

**1. Sensing.** A stream of microvolt samples at a nominal 256 Hz. Today this
comes from `ScenarioEEGGenerator`, which models alpha suppression and rising
frontal theta as a cognitive-load scalar climbs, over pink background noise
with drifting band frequencies.

Nominal, not assumed: the source reports the rate it is *measured* to be
running at, and the analysis is built against that. A real crystal runs at
255.7 or 261 Hz and moves with temperature, and a 60 Hz notch built against
the wrong rate stops notching — at 2% of rate error, over half the mains walks
straight through it.

**2. Signal chain** (`lib/dsp/`).

- One-pole DC blocker at 0.5 Hz.
- 60 Hz RBJ notch biquad (Q = 20) for mains rejection, tuned to the rate the
  device is actually sampling at rather than to the nominal one.
- Goertzel bank over a 512-sample (2.0 s) periodic-Hann window, hop 64, so
  frames land 4× per second with exactly 0.5 Hz bin spacing.
  Theta = 4.0–7.5 Hz, alpha = 8.0–12.0 Hz. Every figure in this paragraph is
  quoted at the nominal rate; on a device sampling faster, the frames land
  faster and the bins are wider, and every duration in the app is derived from
  the measured rate rather than counted in frames against a constant.

  Goertzel rather than an FFT because only 17 of 256 bins are needed, and each
  Goertzel bin is *exactly* the corresponding DFT bin — the band powers are not
  an approximation. Power is normalised one-sided and window-corrected, so a
  pure sine of amplitude A reports A²/2. A 50 µV, 10 Hz tone reads
  alpha = 1250 µV², and a test asserts it.

**3. Cognitive Load Index.** A logistic over the log theta/alpha ratio measured
against a personal baseline captured over the first 15 seconds:

```
r   = ln(P_theta / P_alpha)
CLI = 100 / (1 + exp(-((r - mu) - C) / K))       K = 1.6, C = 1.6
```

Frontal theta rises with mental workload while alpha is suppressed, so the
ratio moves twice as fast as either band alone. Using a *ratio* rather than raw
alpha amplitude is what makes the number robust: electrode impedance, amplifier
gain, and windowing constants all cancel.

Smoothed with an EMA and latched through two thresholds (enter at 70 held for
5 s, leave at 60) so the state does not flicker.

Measured end to end: load 0.15 → 29, 0.50 → 55, 0.75 → 72, 0.90 → 81.

**4. The reset.** A 60 second guided box-breathing protocol. Simulated load
decays as it runs, so the index visibly falls on the meter behind it — the
closed loop the product is built around.

**4b. On a phone.** The first run states what KORE claims before it shows a
reading — it measures the balance of two EEG rhythms, it is a wellness tool and
not a medical device, and it does not diagnose anything — and then pairs. The
pairing screen's contact check is the one hardware demos skip, and it is the
one that matters: a poor electrode does not produce an obviously broken
reading, it produces a *plausible* one, so Continue stays disabled until every
measurable pad is seated and the line under it names the pad rather than
describing the fault.

The app is also suspended constantly on a phone, which the desktop build never
had to survive. A gap longer than one analysis window is refused rather than
spliced: engine ring and filters cleared, predictor trajectory with them, a
full clean window required before a frame is believed again, and a **hole** in
the sparkline instead of a straight line across minutes nobody measured.

**5. Confirm and reinforce.** On completion the app asks a single question —
*how clear do you feel?* — on a 1–5 scale, and pairs the answer with the
measured index drop across the protocol. Each reset is appended to
`%APPDATA%\KORE\history.json` (`~/.kore/history.json` elsewhere), and the
dashboard shows the day streak, mean drop, and mean clarity.

This closes steps 3 and 4 of the core loop in `docs/positioning.md` and is what
makes three of its four key metrics measurable at all. Three deliberate
choices:

- The check-in is only offered when the protocol **ran to the end**. Asking
  "did that help?" after a four-second abort collects noise and calls it a
  metric. Abandoned resets are still logged — abandonment rate is a retention
  signal — but they are excluded from the effectiveness average.
- Resets taken **before calibration finishes** are not logged at all. Without a
  personal baseline the index has nothing to be measured against, so a
  before/after pair from that window would be a number with no meaning.
- The sheet states the measurement plainly, including when the index went
  **up**. A reset that did not work should say so.

The uplift being measured is currently a simulated one — `applyResetRecovery()`
decays the synthetic load. The arithmetic is real; the physiology behind it
waits on hardware.

**6. The tier above the app.** On a phone the most-used surface is one KORE
does not draw. When the app goes into the background during a strain episode it
posts one notification, and the copy is the whole design:

```
KORE — Load 78 for the last 6 minutes
[ Reset ]   [ Not now ]
```

It states the measurement and the duration. It does not say "you seem
stressed", carries no emoji, and posts at DEFAULT importance rather than HIGH
— the same rule as the palette's missing alarm colour: KORE states a bad
reading plainly and never alarms about it. One notification per episode,
updated in place under a fixed id, so ignoring it is not punished with another.
`Not now` suppresses for the rest of the *episode*, not for ten minutes; a
timed snooze would fire again into an episode the user has already declined.
The banner comes down when the episode ends, when the user returns to the app,
and at the *start* of a reset rather than the end.

The duration comes from `CognitiveLoadIndex.strainFor`, which counts measured
frames from the first frame of the run that latched — so it includes the
five-second dwell rather than starting late, and it can never report a duration
spanning a stretch nothing was measured. That is why it is a duration and not
the `strainSince` timestamp originally specified: subtracting a timestamp from
now asserts the episode continued through every minute since, including the
ones the app was suspended for or the electrode was off through. An unusable
frame withdraws the claim and the clock together.

`setKeepScreenOn` is the other half, and the smaller fix for the more obvious
bug: the reset is 60 s of watching an animation without touching the screen,
which outlasts the display timeout. Held for the protocol, released whether it
completed or was abandoned.

**What it cannot do yet.** `KoreSession.pause()` stops the source when the app
is backgrounded, which is the honest response to an OS that has throttled the
timers to nothing — so nothing is measured in the background, and the only
moment this tier can truthfully post is the transition into it. A foreground
service is the right answer the moment there is a radio for it to hold open;
today it would keep a *simulator* running in the background and call the result
a measurement. It drops in behind `StrainNotifier` without changing a rule.

## Architecture notes

- `DspEngine` has two implementations. `DartDspEngine` is the reference;
  `NativeDspEngine` is the C++/FFI port. `createDspEngine()` tries native and
  falls back to Dart on any failure, so a missing library costs a log line
  rather than the app. The Dart path is not a degraded mode — it is the
  implementation the tests validate.
- `EegSource` is the hardware seam. `SimulatedEegSource` implements it today;
  a BLE source drops in behind the same interface without touching the engine,
  the index, or the UI.
- Acquisition (256 Hz) is decoupled from repaint (4 Hz). Samples arrive in
  blocks; `KoreSession` notifies once per completed analysis frame.

### The platform channel

`lib/services/kore_platform.dart` is the first platform code the project has
taken, and `docs/hardware-seam.md` makes the call it rests on: the constraint
is *no pub dependency*, not *no platform code*. One `MethodChannel`, a Kotlin
host in `android/app/src/main/kotlin/`, nothing added to `pubspec.yaml`.

It was taken for the notification tier rather than for BLE on purpose — the
shape is easier to get right where a failure costs one missing banner. Three
properties BLE inherits:

- `createKorePlatform()` is `createDspEngine()` in a different costume: try the
  platform, return an inert implementation otherwise. `_InertPlatform`
  implements every method as a *successful no-op* rather than throwing, which
  is what keeps the Windows build free of platform conditionals entirely.
- Every call is wrapped against `MissingPluginException`, because on a staged
  rollout the Dart half can legitimately know a method the installed APK does
  not implement. Normal condition, not an error.
- Delivery is **pull, not push**, for anything that can arrive before the
  engine exists. A notification button fires a `PendingIntent` that may create
  the process, so the host queues the action and Dart drains it once its
  handler is installed. A host that pushed at engine-attach would fire into a
  channel with nothing listening. The BLE equivalent is a device that connected
  while the app was dead.

### The native path

`cpp/` builds as `kore_signal.dll` alongside `kore.exe` as part of the normal
`flutter build windows`, and `NativeDspEngine` loads it over FFI. Three
Windows-specific things had to be right, and each is commented at the site:

- `extern "C"` controls name mangling, not export. Without
  `__declspec(dllexport)` the DLL builds with an empty export table,
  `DynamicLibrary.open()` *succeeds*, and the failure only surfaces later at
  `lookupFunction` — so a load-succeeded check proves nothing.
- The old `cpp/CMakeLists.txt` set `-O3 -fPIC` globally and linked `c++`;
  cl.exe rejects all three. Those flags now live behind `if(ANDROID)`, and the
  optimisation level is left to CMake per configuration — hardcoding `/O2`
  collides with Debug's `/RTC1`.
- The target is deliberately not routed through Flutter's
  `apply_standard_settings()`, which sets `/WX` and `_HAS_EXCEPTIONS=0`. The
  FFI shim uses try/catch to stop exceptions unwinding across the C boundary.

`test/dsp/native_parity_test.dart` holds the two engines to each other sample
for sample: same frame count, and theta/alpha agreeing to 1e-9 relative. Both
sides are double precision specifically so that tolerance is meaningful — a
float32 core would drift through the Goertzel accumulation and make parity
testing guesswork. The tests skip themselves with a build hint if the DLL is
absent.

The fallback still matters: `createDspEngine()` catches a missing library,
unresolved symbols, and an ABI-version mismatch, so any of the three costs a
log line rather than the app.

## Repo layout

```
lib/dsp/       filters, Goertzel, band power, the index
lib/sources/   EegSource seam, link state, demo controls, simulated generator
lib/session/   pipeline wiring, reset history, quality gate, notification rules
lib/services/  EEG stream types, on-disk history store, platform channel
lib/app/       launch gate, welcome, pairing, dashboard, trend, history
lib/widgets/   gauge, sparkline, reset protocol, check-in, recovery, patch diagram
cpp/           native DSP (C++/FFI), built into the Windows bundle
docs/          product narrative and positioning
landing-page/  static marketing site (Netlify)
tool/          cli_probe.dart, for tuning the index offline
```

## Contact

For inquiries, contact the KORE team.
