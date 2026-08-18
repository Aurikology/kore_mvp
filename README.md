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
| Native C++/FFI DSP path | Scaffolded, not built — falls back to Dart |
| BLE / real hardware | Not implemented (seam in place) |
| Android build | Scaffold only; needs an Android SDK + NDK |
| Post-reset check-in, streaks, persistence | Not implemented |

## Running it

```bash
flutter run -d windows
```

No Android SDK, Developer Mode, or network connection required — the project
has zero plugins and bundles its fonts.

```bash
flutter test                   # 15 tests, including the DSP assertions
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

### Not yet wired up

The native DSP path needs three Windows-specific fixes, all noted in the code:
`cpp/CMakeLists.txt` uses GCC flags and links `c++` (neither works under MSVC),
and `ffi_bindings.cc` has `extern "C"` but no `__declspec(dllexport)` — on
Windows that controls name mangling, not export, so the DLL would build with an
empty export table and fail at symbol lookup rather than at load.

## Repo layout

```
lib/dsp/       filters, Goertzel, band power, the index
lib/sources/   EegSource seam + simulated generator
lib/session/   pipeline wiring and demo controls
lib/widgets/   gauge, sparkline, reset protocol
cpp/           native DSP (not built yet)
docs/          product narrative and positioning
landing-page/  static marketing site (Netlify)
tool/          cli_probe.dart, for tuning the index offline
```

## Contact

For inquiries, contact the KORE team.
