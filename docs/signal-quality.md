# Signal quality: how KORE refuses to lie

The dangerous gap in `docs/hardware-seam.md`, closed. This describes what was
built, and - more usefully - what was decided and what was rejected.

## The failure being defended against

A dry electrode losing contact does not go quiet. It produces a large
sub-alpha artifact from its own half-cell potential and every movement of the
lead, while the physiological signal it was picking up fades out with the
coupling. Theta up, alpha down.

That is the cognitive-load signature, exactly. Not approximately.

So a bad electrode does not produce an obviously broken reading. It produces a
*plausible* one: the meter climbs, strain latches, the app offers a breathing
protocol to somebody whose headband has come off, and logs the whole episode as
reset-effectiveness data. Everything KORE claims about honesty fails at that
point, and it fails silently.

`test/dsp/electrode_artifact_test.dart` runs that exact scenario through the
real DSP chain with quality ignored, and asserts that the index goes past 70 and
latches strain. It is a test that the product *would* lie, kept so the defence
has something to point at.

## The type

`SignalQuality` (`lib/services/signal_quality.dart`) is a live record a source
publishes with every block:

```dart
class SignalQuality {
  final double? contact;         // 0-1 coupling proxy, null = cannot measure
  final double? impedanceKOhm;   // informational; never gates anything
  final int droppedSamples;      // exact, from device-side sample indices
  final double measuredRateHz;   // measured, not claimed
  final double nominalRateHz;
}
```

with `level` (`good` / `degraded` / `unusable`) and `faults` (a set:
`poorContact`, `electrodeDetached`, `dropout`, `sampleRateDrift`, `settling`)
derived from it.

Three decisions are what make it survivable by hardware rather than shaped
around what the simulator finds easy.

**Every measurement is nullable when it cannot be taken.** A front end with no
impedance channel reports `contact: null`, not a fabricated 1.0. Inventing a
perfect score for a device that cannot measure one is the same lie in a
different place. `contactMeasured` is what stops "not measured" being rendered
as "good".

**Raw measurements, banded separately.** The fields are what a device reports;
`level` and `faults` are policy derived from them. A front end that learns to
measure something new adds a field, not a meaning - and the bands are named
constants at the top of the file for the same reason the index's are, because
they are what gets retuned against a real electrode.

**It describes a moment, not a session.** Quality rides on `SampleBlock`, is
re-published with every block, and is *also* available on a stream of its own.
The block is where it belongs because quality has to be attributable: a
separate channel races with the samples, and a race here means a report of good
contact getting applied to the block taken while the electrode was already off.
The stream exists as well because the worst failure sends no blocks at all - a
link that dropped delivers nothing, and a consumer that only learned quality
from arriving samples would hold a stale "good" for as long as the silence
lasted.

`SampleBlock` also carries `firstSampleIndex`, a monotonic device-side counter.
That is what makes a gap *countable* rather than guessed at from arrival times;
`EEGSample.timestamp` is stamped when the app assembled the block and says
nothing about when the device sampled it.

## The gate

`SignalQualityGate` (`lib/session/signal_quality_gate.dart`) turns a per-block
report into a per-*frame* verdict, and exists because the two are not the same
thing. The source reports on the samples it just delivered; the analysis
consumes a 512-sample window, so a fault that has already cleared keeps
contaminating frames until it has slid out the far end of it. Two seconds of
perfect contact after an electrode is re-seated still produce two seconds of
frames half-built from artifact.

Dropout is the sharpest case: the engine writes samples into a ring buffer by
position, so a gap is spliced out silently and the Hann-windowed Goertzel turns
the discontinuity into broadband splatter landing in theta and alpha at once.
One mechanism covers it and everything else - after any unusable report, a full
window of usable samples has to pass before a frame can be believed again. That
interval reports as `SignalFault.settling`, carrying the fault it is settling
from, because "recovering" on its own tells a user nothing they can act on.

## The policy, per consumer

"Hold the last good value", "withhold entirely" and "publish with a quality
flag" are different answers with different failure modes, and the right one is
genuinely different for different consumers. What each one does:

| Consumer | Unusable signal | Why |
| --- | --- | --- |
| The index value | **Hold last, flagged** | A gauge painting nothing is a worse failure than a gauge painting a stale number *labelled stale*. Withholding would also mean every caller handling a null. |
| `LoadState` | **Strain is withdrawn** | Strain asserts sustained load. The instant the signal stops supporting the assertion, the honest move is to stop asserting it - and the case this exists for is precisely an electrode that fell off while the index was high *because* it fell off. Re-earning it costs the usual 5 s dwell. |
| The sparkline | **Nothing appended** | A held value in a trend reads as a measurement of calm, which is the opposite of what happened. |
| The crash predictor | **Silent, window dropped** | A line fitted across a bad patch forecasts the electrode. Treated exactly as calibration is. |
| The daily rollup | **Frames not counted** | The longitudinal record is the last place an artifact should be able to hide. |
| The personal profile | **Learns nothing** | A threshold learned from an artifact is wrong for as long as the user has the app. |
| Reset logging | **Not logged at all** | Following the precedent already set for a reset taken before calibration. Half a measurement in the effectiveness history is worse than a gap in it, because the gap is visible. One unusable frame anywhere in the 60 s is enough. |
| Baseline capture | **Stalls - and the bar is higher** | See below. |

A **degraded** signal is a different answer again: the reading publishes with
the flag set. A warning worth acting on is not withheld over a slipping band.
The one thing degraded does *not* buy is a baseline.

### The baseline gets the strictest gate

Calibration accepts `good` frames only, not merely usable ones. A degraded
reading costs one reading; a baseline captured from degraded frames is the
reference every reading for the rest of the session is measured against, and
there is no recovering from it inside that session.

A bad stretch stalls the capture rather than restarting it: frames already
taken from a good signal are still good, so they neither count nor discount.
`calibrationStalled` on `KoreSession` exists so the UI can explain a countdown
that has stopped counting, which users otherwise read as a crash.

## What was rejected

**A fourth `LoadState`.** `docs/hardware-seam.md` proposed one, and it is the
wrong shape. Load state answers "how loaded is this person"; quality answers
"can we see them at all", and the two are orthogonal - a signal can be unusable
at any load. Folding an absence of measurement into an enum of measurements
puts "no signal" in the same slot a reading goes, which is how it ends up
rendered as one. Two orthogonal facts, two channels, and every consumer checks
both.

**A sixth `CrashForecastStatus`.** Same argument, plus: the answer to *why* the
forecast went quiet already lives on the quality getters, and every existing
switch over those five statuses would have to grow an arm to restate it.

**A dropout ratio threshold.** There is no such thing as a harmless splice
inside a 2 s analysis window, so any gap at all disqualifies. A "5% dropout is
fine" constant would have been a number with nothing behind it.

**Withholding readings from a source that cannot measure contact.** A device
with no impedance front end reads `good`, and this is the one place the type
gives ground: the alternative is that KORE simply does not run on such a
device. Absence of evidence is not evidence of a fault. `contactMeasured` is
what stops it being sold as evidence of health.

**Correcting for sample-rate drift.** Drift is *detected* and gated on; the DSP
still runs at a compile-time 256 Hz. Making `DspEngine` take its rate is step 3
of `docs/hardware-seam.md`, it touches the C++ port and its 1e-9 parity, and it
should be made deliberately rather than smuggled in behind a quality flag.
Refusing to trust a drifted signal is honest in the meantime; silently
mis-analysing one is not.

## The simulator

`ScenarioEEGGenerator` now models the electrode as well as the brain behind it.
`contact` scales the physiological signal and its complement scales a
four-component artifact whose energy sits at 0.6, 2.7, 5.3 and 6.8 Hz - two of
them inside theta, none inside alpha. That is not a convenience; it is the
physics that makes this dangerous.

At `contact == 1.0` the arithmetic is an exact identity - the signal is
multiplied by 1 and the artifact by 0 - and the artifact phases are integrated
from accumulators rather than drawn from the RNG, so no seeded sequence moves.
`test/dsp/published_figures_test.dart` pins the consequence: a fresh user still
reads 70 / 60 and 0.15 -> 29, 0.50 -> 55, 0.75 -> 72, 0.90 -> 81.

`SimulatedEegSource` injects the four failure modes: `setContact`,
`degradeContact` (a band working loose, so each stage of the failure is
visible), `detachElectrode` / `restoreContact`, `dropSamples` (the device still
produces them, the app never sees them, the index jumps by exactly the number
missing), and `setSampleRateError` - which changes how many samples are
actually emitted, because a simulator that reported drift without producing it
would agree with itself and with nothing else.

## What is still not built

- **Link state.** `SourceLinkState` from `docs/hardware-seam.md` is still not
  on the seam. It is connection, not quality, and an enum with one
  implementation that only ever says `streaming` is speculative. The quality
  stream is where a real source reports a link it has lost.
- **A stall watchdog.** If a source stops emitting entirely and says nothing,
  quality stays at its last value. The `qualityUpdates` stream is the seam
  through which a real source reports its own stall; a timer that notices
  silence on the app side is the belt to that braces.
- **Multi-channel quality — the type exists, no source fills it.**
  `SignalQuality.electrodes` carries per-electrode contact, and
  `SignalQuality.fromElectrodes` rolls it up. The combining rule is
  **worst-wins**, not an average: averaging would let one detached pad be
  diluted by three good ones, which is the same shape as the dropout ratio
  threshold rejected above — a tolerance constant with nothing behind it.
  Electrodes that cannot be measured are skipped rather than counted bad.

  Electrodes are deliberately not indexed by data channel. The analysis
  consumes one channel; how many pads produce it belongs to the device, and
  indexing by channel position would make any pad that does not carry its own
  channel unrepresentable.

  What is still missing is a **source that reports it**. `SimulatedEegSource`
  is single-electrode end to end — one coupling scalar mixed into one output
  sample — so nothing per-electrode is demonstrable or regression-testable
  yet. Two known consequences to fix when it is wired:

  - `_publishQuality` emits only when `level` or the fault *set* changes, so a
    pad sliding 0.9 → 0.4 while another is already detached would emit
    nothing, and a per-pad contact view would never repaint. The change
    detector has to compare the per-electrode vector, not the derived scalar.
  - `SignalQualityGate` snapshots `Set<SignalFault>` at contamination, which
    erases *which* pad was bad across the settling window — exactly when the
    user is holding one down waiting for the reading to come back.

  Also unresolved, and not resolvable from the docs: **the montage**. Nothing
  written specifies electrode count, a reference, or which pads feed the
  analysis. Worst-wins over every reported electrode is the conservative
  reading — it withholds rather than over-publishes — but a device whose spare
  pad does not feed the engine would be over-gated by it, and that is a
  question for the first real patch, not for this file.
- **Rate-aware DSP.** Step 3 of `docs/hardware-seam.md`, unchanged.
