# KORE

The digital dashboard for your mind. KORE monitors cognitive load, predicts
focus crashes, and guides a short reset — a behavioural alternative to
nicotine and stimulants for managing academic strain.

## Status

**Working desktop prototype, simulated signal.** The app builds and runs on
Windows, computes a real Cognitive Load Index from a real DSP pipeline, and
closes the detect → reset loop. There is no hardware yet: the EEG stream is
synthetic. **The signal processing is genuine; only the electrode is
simulated.**

| Area | State |
|---|---|
| DSP pipeline (filtering, band power, index) | Implemented, unit-tested |
| Live dashboard (gauge, trend, reset protocol) | Implemented |
| Windows desktop build | Working |
| Simulated EEG source | Implemented |
| Native C++/FFI DSP path | Implemented and built on Windows; parity-tested against Dart |
| BLE / real hardware | Not implemented (seam in place) |
| Android build | Scaffold only; needs an Android SDK + NDK |
| Post-reset check-in, streaks, persistence | Implemented, on-disk, no plugins |

## Running it

```bash
flutter run -d windows
```

No Android SDK, Developer Mode, or network connection required — the project
has zero plugins and bundles its fonts.

```bash
flutter test                   # 254 tests, including the DSP assertions
dart run tool/cli_probe.dart   # sweep load levels and print the index curve
```

## How it works

**1. Sensing.** A stream of microvolt samples at 256 Hz. Today this comes from
`ScenarioEEGGenerator`, which models alpha suppression and rising frontal
theta as a cognitive-load scalar climbs, over pink background noise with
drifting band frequencies.

**2. Signal chain** (`lib/dsp/`).

- One-pole DC blocker at 0.5 Hz.
- 60 Hz RBJ notch biquad (Q = 20) for mains rejection.
- Goertzel bank over a 512-sample (2.0 s) periodic-Hann window, hop 64, so
  frames land 4× per second with exactly 0.5 Hz bin spacing.
  Theta = 4.0–7.5 Hz, alpha = 8.0–12.0 Hz.

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
lib/sources/   EegSource seam + simulated generator
lib/session/   pipeline wiring, reset history, demo controls
lib/services/  EEG stream types + on-disk history store
lib/widgets/   gauge, sparkline, reset protocol, check-in, recovery
cpp/           native DSP (C++/FFI), built into the Windows bundle
docs/          product narrative and positioning
landing-page/  static marketing site (Netlify)
tool/          cli_probe.dart, for tuning the index offline
```

## Contact

For inquiries, contact the KORE team.
