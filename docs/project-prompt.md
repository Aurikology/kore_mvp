# KORE — Project Prompt

A single self-contained briefing. Paste this into any agent or tool that needs
to understand KORE without reading the repo.

---

## What KORE is

KORE is a closed-loop cognitive-load system for students: it measures mental
strain from an EEG signal, predicts focus crashes, and guides a short reset —
a behavioural alternative to nicotine and stimulants for managing academic
strain.

The product thesis is the loop, not the sensor:

1. **Detect** strain or focus drift.
2. **Trigger** a short reset protocol.
3. **Confirm** uplift with a one-question check-in.
4. **Reinforce** with streaks and recovery trends.

Positioning: wellness and performance language only. Not a medical device in
this phase, not a treatment, not a generic meditation app.

## What exists today (working prototype)

A **Flutter desktop app** running on Windows. Real DSP, simulated electrode —
the signal processing is genuine; only the EEG source is synthetic. There is
no server, no accounts, no network. 52 tests pass.

**Signal chain** (`lib/dsp/`), 256 Hz microvolt samples:
- One-pole DC blocker at 0.5 Hz.
- 60 Hz RBJ notch biquad (Q = 20) for mains rejection.
- Goertzel bank over a 512-sample (2.0 s) periodic-Hann window, hop 64 → 4
  frames/sec, exactly 0.5 Hz bin spacing. Theta 4.0–7.5 Hz, alpha 8.0–12.0 Hz.
  Goertzel rather than FFT because only 17 of 256 bins are needed and each
  Goertzel bin is *exactly* the corresponding DFT bin. Power is normalised
  one-sided and window-corrected: a 50 µV 10 Hz tone reads alpha = 1250 µV²,
  and a test asserts it.

**Cognitive Load Index** — logistic over the log theta/alpha ratio against a
personal baseline captured over the first 15 seconds:

```
r   = ln(P_theta / P_alpha)
CLI = 100 / (1 + exp(-((r - mu) - C) / K))     K = 1.6, C = 1.6
```

Using a ratio rather than raw alpha is what makes it robust — impedance,
amplifier gain, and windowing constants cancel. EMA-smoothed and latched
through two thresholds (enter 70 held 5 s, leave 60) so state does not
flicker. Measured end to end: load 0.15 → 29, 0.50 → 55, 0.75 → 72, 0.90 → 81.

**The reset** — 60 s guided box-breathing protocol. Simulated load decays as it
runs, so the index visibly falls on the meter behind it.

**Confirm and reinforce** — on completion the app asks *how clear do you feel?*
(1–5) and pairs the answer with the measured index drop. Appended to
`%APPDATA%\KORE\history.json`. Dashboard shows day streak, mean drop, mean
clarity. Three deliberate rules: the check-in is only offered when the protocol
ran to the end; resets before calibration finishes are not logged at all; the
sheet states the measurement plainly, including when the index went **up**.

**Native path** — `cpp/` builds as `kore_signal.dll` into the Windows bundle
and `NativeDspEngine` loads it over FFI. `createDspEngine()` tries native and
falls back to Dart on missing library, unresolved symbol, or ABI mismatch, so
failure costs a log line rather than the app. `native_parity_test.dart` holds
both engines to 1e-9 relative agreement; both are double precision so that
tolerance is meaningful.

**Seams already in place:**
- `EegSource` — the hardware seam. `SimulatedEegSource` implements it today; a
  BLE source drops in behind the same interface without touching the engine,
  the index, or the UI.
- `DspEngine` — two implementations, Dart reference + native C++.
- Acquisition (256 Hz) is decoupled from repaint (4 Hz).

**Repo layout:**
```
lib/dsp/       filters, Goertzel, band power, the index
lib/sources/   EegSource seam + simulated generator
lib/session/   pipeline wiring, reset history, demo controls
lib/services/  EEG stream types + on-disk history store
lib/widgets/   gauge, sparkline, reset protocol, check-in, recovery
cpp/           native DSP (C++/FFI), built into the Windows bundle
test/          52 tests
docs/          product narrative and positioning
landing-page/  static marketing site (Netlify)
tool/          cli_probe.dart, for tuning the index offline
```

Stack: Flutter/Dart, zero plugins, bundled fonts. Targets present: `windows/`
(builds and runs), `android/` (scaffold only, needs SDK + NDK). No `web/`.

## What is NOT built

- BLE / real hardware. The seam exists; nothing speaks to a device.
- Android build.
- Any server, account system, sync, or cloud inference.
- Real recovery physiology — `applyResetRecovery()` decays the synthetic load,
  so the measured uplift is arithmetic over a simulation.

## What KORE becomes

A non-invasive neurotechnology platform: a **wearable EEG patch** paired with a
**mobile app**, with AI inference for prediction and personalization.

- **Hardware.** EEG (and eventually tACS) patch doing edge sensing, streaming
  over BLE into the existing `EegSource` seam.
- **Mobile.** Phone becomes the primary surface; desktop stays as the
  development and demo surface.
- **Prediction.** Move from measuring current load to forecasting a focus crash
  before it lands, and personalising thresholds per user rather than per
  session.
- **Backend.** Accounts, cross-device history sync, longitudinal trends, and
  hosted inference — none of which exists yet.

Key metrics the product is judged on: focus session completion rate, reset
effectiveness (pre/post clarity delta), weekly focus minutes and streaks, and
7-/14-day retention.

## UX principles

Minimal, clean, low visual burden. High readability, predictable interaction.
Fast insight with low cognitive overhead — the user is, by definition, already
cognitively overloaded when they open it.
