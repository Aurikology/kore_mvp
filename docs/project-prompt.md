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

A **Flutter app** running on Windows and Android. Real DSP, simulated
electrode — the signal processing is genuine; only the EEG source is synthetic.
There is no server, no accounts, no network. 361 tests pass.

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

**The notification tier** (`lib/services/kore_platform.dart`,
`lib/session/strain_notifier.dart`). The first platform code the project has
taken, and the thing `docs/hardware-seam.md` argued for: an in-repo
`MethodChannel` with a Kotlin host, no pub package, nothing added to
`pubspec.yaml`, nothing a host-VM test has to bind. Taken for a notification
rather than for BLE deliberately — the shape is easier to get right where a
failure costs one missing banner than where it costs a dropped EEG link.

The copy is fixed: **`KORE — Load 78 for the last 6 minutes`**, with `Reset`
and `Not now`. It states the measurement and the duration, carries no emoji,
and posts at DEFAULT importance rather than HIGH — the same rule as the
palette's missing alarm colour. One notification per episode, updated in place
under a fixed id. `Not now` suppresses for the rest of the *episode*, never on
a timer: a snooze would fire again into an episode the user has already
declined, which is escalation wearing a politer name. It speaks only when the
app is not in front, and comes down at the *start* of a reset rather than the
end.

Three properties BLE inherits. `createKorePlatform()` is `createDspEngine()` in
a different costume — try the platform, return an inert implementation
otherwise — and the inert one is a *successful no-op* rather than a throw, so
the Windows build carries no platform conditionals at all. Every call is
wrapped against `MissingPluginException`, because a Dart build newer than the
installed APK is a normal condition rather than an error. And delivery is
**pull, not push**: a notification button fires a `PendingIntent` that may
create the process, so the host queues the action and Dart drains it once its
handler exists. A host that pushed at engine-attach would fire into a channel
with nothing listening; the BLE equivalent is a device that connected while the
app was dead.

**`strainFor`**, the duration the notification states, and deliberately a
duration rather than the `strainSince` timestamp originally specified.
`CognitiveLoadIndex` counts measured frames from the first frame of the run
that latched — so it includes the five-second dwell rather than starting
late, and it can never report a duration spanning a stretch nothing was
measured. A timestamp subtracted from now asserts the episode continued through
every minute since, including the ones the app was suspended for. An unusable
frame withdraws the claim and the clock together. Same rule as the sparkline's
hole.

**Screen-wake during a reset.** 60 s of watching an animation without touching
the screen outlasts the display timeout. Held for the protocol, released
whether it completed or was abandoned — the flag is not one to leave set.

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

**Signal quality** (`lib/services/signal_quality.dart`,
`lib/session/signal_quality_gate.dart`). The hazard this exists for: a detached
electrode produces theta-up and alpha-down, which is the cognitive-load
signature exactly — so a bad electrode does not produce an obviously broken
reading, it produces a *plausible* one. `test/dsp/electrode_artifact_test.dart`
demonstrates it on the real DSP chain: with quality ignored, a floating
electrode reads past 70 and latches strain, and the app would have offered a
reset for it.

`SignalQuality` rides on every block (attributable — a separate channel races
and can label the block taken while the electrode was already off), with a
`qualityUpdates` stream alongside it because a dropped link sends no blocks at
all. Every measurement is **nullable when it cannot be taken**: a front end
with no impedance channel reports `null`, never a fabricated 1.0, and
`contactMeasured` stops "not measured" rendering as "good". `SignalQualityGate`
widens the per-block report to the 512-sample analysis window and requires a
full clean window before believing a frame again.

The policy, per consumer: the index **holds its last value, flagged** (a gauge
painting nothing is worse than one painting a number labelled stale); strain is
**withdrawn**, not held, because the case this exists for is an electrode that
fell off while the index was high *because* it fell off; the sparkline, daily
rollup, profile learning and predictor **take nothing**, since a held value in
a trend reads as a measurement of calm; a reset with one unusable frame
anywhere in its 60 s is **not logged at all**; and baseline capture accepts
`good` frames only, stalling rather than restarting. Reasoning and rejected
alternatives in `docs/signal-quality.md`.

**Responsive layout** — the dashboard builds one widget list into three
layouts by *window class, not platform*, so a narrow desktop window gets the
phone layout. Regression-tested at seven widths from 320 px to 1920 px.

**Native path** — `cpp/` builds as `kore_signal.dll` into the Windows bundle
and `NativeDspEngine` loads it over FFI. `createDspEngine()` tries native and
falls back to Dart on missing library, unresolved symbol, or ABI mismatch, so
failure costs a log line rather than the app. `native_parity_test.dart` holds
both engines to 1e-9 relative agreement; both are double precision so that
tolerance is meaningful.

**The link** (`lib/sources/source_link.dart`). `start()` returns a future that
either completes or throws, which is the wrong shape for a radio: it scans,
connects, drops and reconnects, and the user needs to see all of it.
`SourceLink` publishes those states alongside the future, with the patch
identity and a **nullable** battery on it — a device that cannot report one
says so rather than showing full. It sits beside a `linkUpdates` stream for the
same reason `qualityUpdates` exists, only sharper: a link that is scanning
produces no blocks at all, so every state on the way to `streaming` is
invisible from the sample stream. The pairing screen is made entirely of those
states.

**First run** (`lib/app/kore_launch.dart`). Welcome states the claim boundary
before the first reading appears, because afterwards it reads as walking back
something the user already believes. Pair is three states in one screen, and
its contact check is where the honesty rule meets hardware: Continue is
disabled until every *measurable* pad is seated, the line under it names the
pad ("press the left pad down") rather than describing the fault, and an
unmeasurable pad reads "Not measured" and blocks nothing — not evidence of a
fault, not evidence of health. Shown once ever, recorded in an `AppState`
section of the document; an unparseable section reads as *not* onboarded,
because that costs one avoidable screen where the other direction skips the
claim boundary entirely.

**History** (`lib/app/history_screen.dart`). Every reset, newest first, grouped
by day, reached by tapping the recovery card rather than from a tab bar.
Abandoned resets are shown, greyed and labelled: abandonment is a retention
signal and hiding it would flatter the record. The drop figure is uncoloured in
both directions — the check-in sheet states a rise in the same secondary text
as a fall, and a history that painted the good ones green would be grading the
user rather than reporting the measurement.

**Suspend and resume.** `start()` assumed a stream that never stops; a phone
suspends the app constantly and does not ask. A gap longer than one analysis
window is refused rather than spliced — samples from either side of a
suspension sit adjacent in a ring buffer written by position, and the
Hann-windowed Goertzel turns that discontinuity into broadband power landing in
theta and alpha at once. So the ring and filters are cleared, the predictor
trajectory with them, a full clean window is required before a frame is
believed again, and the sparkline gets a **hole** rather than a line across
minutes nobody measured. A gap shorter than one window is left alone: every
refusal costs a two-second settle.

**Seams already in place:**
- `EegSource` — the hardware seam. `SimulatedEegSource` implements it today; a
  BLE source drops in behind the same interface without touching the engine,
  the index, or the UI. It carries link state, device-side sample indices,
  per-block quality and a measured sample rate. What it still cannot express is
  written up in `docs/hardware-seam.md`.
- `DemoControls` — the simulator's levers, held separately so `KoreSession` can
  hold an `EegSource` rather than a `SimulatedEegSource`. A real source returns
  null and the demo panel is not built at all.
- `DspEngine` — two implementations, Dart reference + native C++.
- Acquisition (256 Hz) is decoupled from repaint (4 Hz).

**Repo layout:**
```
lib/dsp/       filters, Goertzel, band power, the index, prediction, profile
lib/sources/   EegSource seam, link state, demo controls, simulated generator
lib/session/   pipeline wiring, reset history, daily rollup, quality gate,
               notification rules
lib/services/  EEG stream types, on-disk history store, platform channel
lib/theme/     design tokens: primitives, colours, metrics, components
lib/widgets/   gauge, sparkline, reset protocol, check-in, recovery, diagram
lib/app/       launch gate, welcome, pairing, dashboard, trend, history
cpp/           native DSP (C++/FFI), built into the Windows and Android bundles
android/       Kotlin host for the platform channel (notifications, screen-wake)
test/          361 tests
docs/          product narrative, positioning, design specs, hardware seam
landing-page/  static marketing site (Netlify)
tool/          cli_probe.dart, for tuning the index offline
```

Stack: Flutter/Dart, zero pub plugins, bundled fonts, one in-repo platform
channel. Targets present: `windows/`
and `android/`, both building and running. No `web/`.

## What is NOT built

- BLE / real hardware. The seam exists; nothing speaks to a device. The
  platform-code *decision* it waited on is no longer open — the notification
  tier above is an in-repo `MethodChannel` with a Kotlin host — but the radio
  itself is unwritten.
- **Measurement in the background.** `KoreSession.pause()` stops the source
  when the app is backgrounded, so nothing is measured there and the
  notification tier can only truthfully post at the transition into it. A
  foreground service is the answer once there is a radio to hold open; today it
  would keep a *simulator* running in the background and call the result a
  measurement. It drops in behind `StrainNotifier` without changing a rule.
- Any server, account system, sync, or cloud inference.
- Real recovery physiology — `applyResetRecovery()` decays the synthetic load,
  so the measured uplift is arithmetic over a simulation.
- **Today's bar is missing from the trend.** `dailyLoad` excludes what the
  current session has measured since the last write, and the session only
  writes when the baseline lands or a reset commits — so a session with no
  reset contributes nothing until it ends. The trend screen states this in a
  footnote rather than faking the bar.
- **Multi-channel signal quality.** The quality path is single-channel; a
  four-electrode patch will need per-channel reports and a combining rule.
- **A stall watchdog.** If a source stops emitting *and* says nothing, quality
  holds its last value. `qualityUpdates` is the seam a real source reports its
  own stall through, and `SourceLink.reconnecting` is what it should be saying.
- **A configurable sample rate in the DSP.** The source measures and reports
  its real rate and the quality path bands drift as degraded and unusable, but
  `DspConfig.sampleRateHz` is still a compile-time 256.0 — so a drifting
  crystal is currently *detected* rather than *accommodated*.
- **An index series per reset.** The history screen can say what a reset moved
  but not draw the shape of it: the trajectory lives only in a 120-second
  in-memory ring.

## What KORE becomes

A non-invasive neurotechnology platform: a **wearable EEG patch** paired with a
**mobile app**, with AI inference for prediction and personalization.

- **Hardware.** EEG (and eventually tACS) patch doing edge sensing, streaming
  over BLE into the existing `EegSource` seam. The dependency call is made and
  now has a working instance: the constraint is *no pub dependency*, not *no
  platform code* — an in-repo platform channel, never a pub BLE package. The
  notification tier walked that path first, so BLE inherits the fallback shape,
  the `MissingPluginException` handling, and the pull-not-push delivery rule
  rather than rediscovering them with a radio attached.
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
