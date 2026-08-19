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
no server, no accounts, no network. 135 tests pass.

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
personal baseline:

```
r   = ln(P_theta / P_alpha)
CLI = 100 / (1 + exp(-((r - mu) - C) / K))     K = 1.6, C = 1.6
```

Using a ratio rather than raw alpha is what makes it robust — impedance,
amplifier gain, and windowing constants cancel. EMA-smoothed (tau ≈ 2.1 s) and
latched through two thresholds so state does not flicker. A fresh user
reproduces the published figures exactly: enter 70 / leave 60, and load 0.15 →
29, 0.50 → 55, 0.75 → 72, 0.90 → 81.

**Focus-crash prediction** (`lib/dsp/focus_crash_predictor.dart`). The index
reports the present; this reports the near future. It fits a line by ordinary
least squares to the last 12 s of index trajectory and asks when that line
reaches the enter threshold; inside a 20 s horizon it emits a `CrashForecast`
carrying seconds-to-crossing, confidence, both slopes, and R². Two decisions
carry it:

- **Extrapolate the index, corroborate with the ratio.** The index is what the
  threshold is defined against, so it is the only honest thing to extrapolate —
  but it is an EMA, and an EMA keeps climbing for seconds after its driver has
  turned over. A clearly falling raw theta/alpha ratio vetoes the forecast:
  a rising index with a falling ratio is smoothing momentum, not a crash.
- **Everything is a straight line**, because a linear fit has one parameter to
  justify and an R² that says out loud how well it describes the data. That R²
  is what stops noise sitting just under the threshold from raising an alarm.

Five statuses (`uncalibrated`, `warmingUp`, `steady`, `crashLikely`,
`alreadyStrained`) rather than a bool, because "no warning" has four different
meanings. Nothing is published before calibration or before 6 s of trajectory.
End to end on the real pipeline the warning lands **15 s ahead** of strain
latching.

**Adaptive per-user thresholds** (`lib/dsp/load_profile.dart`). The baseline
and thresholds are personal and persist across sessions. The enter threshold
sits one sigma above the user's own mean, bounded to [55, 85], and exit follows
at the published 10-point gap — *position personalises, the gap never does*,
since the gap is the entire no-flicker mechanism. Baseline capture is also
guarded: a user who opens the app already strained would otherwise calibrate
against a strained ratio and read "steady" for an hour, so a capture more than
0.8 log units from the personal baseline is pulled back to the edge of that
band. Running statistics forget past 50 minutes of measured load, so a profile
tracks a user who changes.

**The reset** — 60 s guided box-breathing protocol, with a haptic tap at each
of the four phase boundaries so it does not require watching the screen.
Simulated load decays as it runs, so the index visibly falls on the meter
behind it.

**Confirm and reinforce** — on completion the app asks *how clear do you feel?*
(1–5) and pairs the answer with the measured index drop. Dashboard shows day
streak, mean drop, mean clarity. Three deliberate rules: the check-in is only
offered when the protocol ran to the end; resets before calibration finishes
are not logged at all; the sheet states the measurement plainly, including when
the index went **up**.

**Persistence** — `%APPDATA%\KORE\history.json` (`~/.kore/history.json`
elsewhere) is a versioned document carrying resets, the load profile, and a
daily rollup. A v1 bare array reads straight through and upgrades on the next
write. The store re-reads before every write rather than holding the document
in memory, because a session only ever owns part of it and writing back a whole
document assembled from a partial view is how one half silently erases the
other. A corrupt file degrades to empty rather than crashing; one bad record
costs only that record; every section is bounded.

**Design system** (`lib/theme/`) — three layers: `primitives` (raw, no
meaning) → `colors`/`metrics` (semantic roles, spacing, type, radius,
elevation, motion, breakpoints) → `components` (per-component derivations).
Colour is a `ThemeExtension` rather than statics, because the gauge and
sparkline are `CustomPainter`s with no `BuildContext`. Light and dark both
ship; the app follows `ThemeMode.system`.

The load ramp runs **cool → warm** (teal → sage → ochre → amber → rust), not
green → red: green-to-red is the exact axis red-green colour blindness
collapses, and the old ramp's bottom quarter was indistinguishable under
deuteranopia. Cool → warm keeps the blue-yellow component every common
deficiency preserves, and every stop clears 4.5:1 in both themes. Colour is
never the only channel — numeral, state word, arc fill and threshold tick all
carry the reading. There is deliberately **no alarm colour** in the palette:
KORE states a bad reading plainly and never alarms about it.

**Responsive layout** — the dashboard builds one widget list into three
layouts by *window class, not platform*, so a narrow desktop window gets the
phone layout. Regression-tested at seven widths from 320 px to 1920 px.

**Native path** — `cpp/` builds as `kore_signal.dll` into the Windows bundle
and `NativeDspEngine` loads it over FFI. `createDspEngine()` tries native and
falls back to Dart on missing library, unresolved symbol, or ABI mismatch, so
failure costs a log line rather than the app. `native_parity_test.dart` holds
both engines to 1e-9 relative agreement; both are double precision so that
tolerance is meaningful.

**Seams already in place:**
- `EegSource` — the hardware seam. `SimulatedEegSource` implements it today; a
  BLE source drops in behind the same interface without touching the engine,
  the index, or the UI. What it still cannot express is written up in
  `docs/hardware-seam.md`.
- `DspEngine` — two implementations, Dart reference + native C++.
- Acquisition (256 Hz) is decoupled from repaint (4 Hz).

**Repo layout:**
```
lib/dsp/       filters, Goertzel, band power, the index, prediction, profile
lib/sources/   EegSource seam + simulated generator
lib/session/   pipeline wiring, reset history, daily rollup, demo controls
lib/services/  EEG stream types + on-disk history store
lib/theme/     design tokens: primitives, colours, metrics, components
lib/widgets/   gauge, sparkline, reset protocol, check-in, recovery
lib/app/       the dashboard shell and its three responsive layouts
cpp/           native DSP (C++/FFI), built into the Windows bundle
test/          135 tests
docs/          product narrative, positioning, design specs, hardware seam
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
- **The daily trend is not rendered.** `dailyLoad` is on `KoreSession` and
  nothing shows it, so the longitudinal record the store now keeps is only
  visible in the file. The forecast and the personal threshold *are* on screen.
- **Electrode contact quality**, which the source cannot report at all. This is
  the dangerous gap: a loose electrode produces theta-up/alpha-down — exactly
  the load signature — so the app cannot currently distinguish a calm reading
  from a detached one.

## What KORE becomes

A non-invasive neurotechnology platform: a **wearable EEG patch** paired with a
**mobile app**, with AI inference for prediction and personalization.

- **Hardware.** EEG (and eventually tACS) patch doing edge sensing, streaming
  over BLE into the existing `EegSource` seam. The dependency call: the
  constraint is *no pub dependency*, not *no platform code* — an in-repo
  platform channel, never a pub BLE package.
- **Mobile.** Phone becomes the primary surface; desktop stays as the
  development and demo surface. The flow and screen inventory are designed in
  `docs/design/mobile.md`. On a phone the inversion matters: the patch tells
  you you are strained, so the notification is the primary surface and the app
  must answer "what now?" above the fold.
- **Backend.** Accounts, cross-device history sync, longitudinal trends, and
  hosted inference — none of which exists yet.

Key metrics the product is judged on: focus session completion rate, reset
effectiveness (pre/post clarity delta), weekly focus minutes and streaks, and
7-/14-day retention.

## UX principles

Minimal, clean, low visual burden. High readability, predictable interaction.
Fast insight with low cognitive overhead — the user is, by definition, already
cognitively overloaded when they open it.
