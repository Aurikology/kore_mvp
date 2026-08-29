# What a real BLE EegSource will ask of the seam

Design note. Nothing here is implemented, and nothing here should be
implemented until there is a radio to test it against. The point is to write
down what the current seam is missing *now*, while there is exactly one
implementation behind it and changing it is free — the same reason
`EEGSample.fromBLEBytes` pins the wire format before any firmware exists.

## The seam as it stands

```dart
abstract class EegSource {
  Stream<List<EEGSample>> get sampleBlocks;
  int get samplingRateHz;
  String get label;
  Future<void> start();
  Future<void> stop();
  void dispose();
}
```

This is the right shape. Blocks rather than single samples is the decision that
matters, and it is already correct: it decouples the 256 Hz acquisition from
the 4 Hz analysis frame and from the repaint, and it gives a BLE notification
handler somewhere natural to land. `SimulatedEegSource` sits behind it today
and `KoreSession` knows nothing else about where samples come from.

What it is missing is everything about the link being *unreliable*. The
interface describes a source that always works, and a radio attached to a dry
electrode on a moving head is not that.

## Four things it cannot express

### 1. Connection state

`start()` returns a `Future<void>` that either completes or throws. A BLE link
is not a function call — it scans, connects, negotiates an MTU, subscribes,
drops, and reconnects, and the user needs to see all of it. Today the only
thing the UI can say about the source is `label`, a fixed string.

The engine does not need this, but the screen does, and routing it around the
seam instead of through it is how a second, informal source interface gets
invented.

### 2. Dropout

Notifications get lost. When they do, the next block arrives with a hole in it
that nothing in the current types can describe: `EEGSample.timestamp` is
`DateTime.now()` taken once when the block is assembled, identical for every
sample in it, so it says when the *app* saw the block, not when the *device*
sampled it.

This matters more than it looks. `DartDspEngine` writes samples into a ring
buffer by position; a gap is spliced out silently, and the Hann-windowed
Goertzel turns the resulting discontinuity into broadband splatter that lands
in both bands at once. The index would move, the crash predictor would see a
trajectory, and neither would be describing the user.

What the seam needs is a monotonic device-side sample counter on each block, so
the consumer can compute exactly how many samples went missing and decide what
to do — most likely discard the analysis window that spans the gap, the way
calibration already refuses to produce an index it cannot stand behind.

### 3. Sample-rate drift

`samplingRateHz` is on the interface and nothing reads it. The DSP takes
`DspConfig.sampleRateHz = 256.0`, a compile-time constant, and builds the DC
blocker, the 60 Hz notch, and every Goertzel bin frequency from it. A real
device's crystal will run at 255.7 or 256.4 Hz, and it will drift with
temperature.

The spectral consequence is small — a 0.3% error moves the 12 Hz bin edge by
0.036 Hz, well inside a 0.5 Hz bin — but two other things are not small. The
notch is tuned to a mains frequency that is genuinely 60.000 Hz; a Q = 20 notch
is narrow, and a 0.3% rate error detunes it by 0.18 Hz, which is a meaningful
fraction of its bandwidth. And the frame rate stops being 4 Hz, which is baked
into `kEmaAlpha`, `kStrainDwellFrames`, `kCalibrationSeconds`, and every
constant in `FocusCrashPredictor`.

The honest fix is to have the source report its *measured* rate, not its
nominal one, and to have the engine be constructed against it rather than
against a constant. That is a real change to `DspEngine` and to the C++ port
behind it, and it should be made deliberately rather than discovered.

### 4. Impedance and signal quality

This is the one that can make the product lie.

A dry electrode losing contact does not produce silence. It produces a large
low-frequency artifact and a collapse in alpha — theta up, alpha down, which is
*exactly* the signature the Cognitive Load Index is built to read as cognitive
load. An app that tells a user with a loose headband that they are in strain,
and then offers to fix it with a breathing protocol, is worse than an app that
says nothing.

There is no defence against this anywhere in the current pipeline, and there
cannot be one inside the DSP: the ratio is genuinely elevated. It has to come
from the hardware, as a per-frame quality signal — electrode impedance, railing
detection, or at minimum a contact flag — and it has to be able to suppress the
index the same way calibration does. `LoadState` already has the right shape
for this; it needs a fourth value meaning *the signal is not usable*, and the
crash predictor needs to treat that state the way it treats `calibrating`.

## What that means for the interface

Roughly:

```dart
enum SourceLinkState { idle, scanning, connecting, streaming, reconnecting, failed }

class SampleBlock {
  final List<EEGSample> samples;
  /// Device-side index of the first sample. Gaps are computed, not guessed.
  final int firstSampleIndex;
  /// 0-1, or null when the source cannot measure it.
  final double? contactQuality;
}

abstract class EegSource {
  Stream<SampleBlock> get sampleBlocks;
  Stream<SourceLinkState> get linkState;
  /// Measured, not nominal.
  double get effectiveSampleRateHz;
  ...
}
```

`SimulatedEegSource` implements all of it trivially — perfect quality, no gaps,
exactly 256 Hz — and that is the point: the additions can be made, tested, and
wired through `KoreSession` and the index with no hardware at all, and the
simulated source can then be made to *inject* dropouts and contact loss so the
handling is tested before the radio exists.

## The dependency decision it forces

BLE cannot be reached from pure Dart on any platform Flutter targets. That
collides directly with the project's zero-plugin property, which is not a
preference — it is what lets the Windows build work without Developer Mode and
lets every DSP and session test run on the host VM with no Flutter binding.

Three options, and only one of them is any good.

**A pub BLE package** (`flutter_reactive_ble`, `flutter_blue_plus`). This is the
option to refuse, and `pubspec.yaml` already records why for the first of them:
it declares only android/ios platform defaults, so on Windows it resolves to an
unimplemented platform interface. Taking it would mean the Windows build
requires symlink support and Developer Mode, the test suite grows a Flutter
binding dependency, and desktop *still* has no BLE. Paying the whole cost for
none of the benefit.

**FFI to the platform radio.** The plumbing already exists and is proven:
`cpp/` builds into the Windows bundle as part of a normal `flutter build
windows`, and `NativeDspEngine` loads it over `dart:ffi` with a working
fallback. Windows BLE via WinRT `Windows.Devices.Bluetooth` fits that path
exactly. Android does not: its BLE API is Java, and `dart:ffi` cannot reach it
without JNI glue that is substantially harder than the platform channel it
would be replacing.

**An in-repo platform channel.** This is the answer, and it turns on a
distinction worth being explicit about: the constraint is *no pub dependency*,
not *no platform code*.

**This is no longer hypothetical.** `lib/services/kore_platform.dart` and its
Kotlin host are the first instance, taken for the notification tier rather than
for the radio - deliberately, because the shape is easier to get right where a
failure costs one missing banner than where it costs a dropped EEG link. What
it establishes, and what BLE inherits:

- One `MethodChannel` in the repo, nothing in `pubspec.yaml`, no symlink
  requirement, nothing a host-VM test has to bind. `flutter test` still runs
  the whole suite with no Flutter binding beyond the framework's own.
- `createKorePlatform()` is `createDspEngine()` in a different costume: try the
  platform, return an inert implementation otherwise. `_InertPlatform`
  implements every method as a successful no-op rather than throwing, so the
  Windows build carries no conditionals at all - which is the property that
  keeps a platform capability from leaking into five call sites.
- Every call is wrapped against `MissingPluginException`, because on a staged
  rollout the Dart half can legitimately know about a method the installed APK
  does not implement. That is a *normal* condition, not an error, and it has to
  degrade rather than take down the frame that called it.
- Delivery is **pull, not push**, for anything that can arrive before the
  engine exists. A notification button press fires a `PendingIntent` that can
  create the process, so the host queues the action and Dart drains it once its
  handler is installed. A host that pushed at engine-attach time would fire
  into a channel with nothing listening. The BLE equivalent is a device that
  connected while the app was dead. A `MethodChannel`/`EventChannel` written inside this
repo — Kotlin on Android, WinRT over FFI or a small C++ shim on Windows — adds
no package to `pubspec.yaml`, no symlink requirement, and nothing that a host-VM
test has to load. `EegSource` is already the abstraction that keeps it out of
everything downstream, and `createDspEngine()`'s try-native-fall-back-to-Dart
pattern is the model for how the app should behave when there is no radio:
`createEegSource()` returns the BLE source if the platform has one and the
simulated source otherwise, and the UI keeps saying which, out loud.

## Order of work

1. ~~Widen `EegSource`~~ — **done.** `SampleBlock` carries a device-side
   `firstSampleIndex` and its own quality report; `effectiveSampleRateHz` is
   measured rather than nominal; `SourceLink` publishes scanning, connecting,
   streaming, reconnecting and failed, with the patch identity and battery on
   it. `SimulatedEegSource` implements all of it and injects every fault it
   describes: degrading contact per pad, a detached pad, lost samples, a
   drifting crystal, and a dropped radio.

   One thing came out of this that was not in the sketch above.
   `KoreSession` was typed against `SimulatedEegSource`, so the seam that is
   supposed to make hardware a drop-in was one the session reached straight
   past. The simulator's levers now sit behind `DemoControls`, which a real
   source does not offer — and which is also why the demo panel disappears on
   a device rather than being hidden behind a flag.

2. ~~Give `LoadState` an unusable-signal value~~ — **done differently, and the
   difference is the interesting part.** A fourth `LoadState` would have made
   "the signal is bad" a state of the *index*, and it is not: the index is a
   reading, and whether the reading can be believed is a property of the
   signal underneath it. `SignalQuality` and `SignalQualityGate` carry it
   instead, and each consumer applies its own policy — the index holds its
   last value flagged, strain is *withdrawn*, the sparkline and the profile
   take nothing at all. Those are four different right answers, and one enum
   value could only have expressed one of them. See `docs/signal-quality.md`.

3. ~~Make `DspEngine` take its sample rate rather than reading a constant~~ —
   **done**, and the C++ port turned out to need no change at all. The rate was
   always a parameter of `kore_dsp_create`, which builds its DC blocker and its
   notch from whatever it is handed; only the Dart half was passing it a
   constant. Parity is now checked at 261.12 Hz as well as at 256, and it
   passes against a DLL built before the change — which is the cleanest
   evidence available that the native side was right all along.

   `DspConfig` splits into geometry and rate. The window, the hop, the bin
   edges and the mains notch stay static: they are design decisions, identical
   on every device. The rate arrives from the source at runtime, and
   `KoreSession` builds the engine, the index, the predictor and the quality
   gate against that one answer, so nothing can be counting frames at 4 Hz
   while the engine frames at 4.08.

   Two things came out of this that were not in the sketch above.

   **How much the notch was actually worth.** On a unit-amplitude 60 Hz mains
   tone, an engine tuned to the real rate leaves 0.00019. One built against
   256 Hz while the device samples at 261.12 leaves 0.53920 — over half the
   mains survives a filter whose entire purpose is removing it. Even 0.5% of
   rate error, ordinary for an uncompensated oscillator, lets a fifth through.
   The estimate above called this "not small" and understated it.

   **Accommodating a rate has to *retire* the fault for it.** This is the half
   that makes the change do anything. The quality path banded drift against the
   256 Hz constant, so a headset whose crystal steadily ran at 261.12 Hz
   reported `sampleRateDrift` on every block, the gate refused every frame, and
   it could never finish calibrating — a perfectly good device, permanently
   unusable. Tuning the engine to it without also moving what drift is measured
   against would have fixed the arithmetic and left the app just as broken.
   `SignalQuality.nominalRateHz` is now `referenceRateHz`, meaning the rate the
   analysis is tuned to; the source fills it with its own nominal, because that
   is all it can know, and `SignalQualityGate` re-references it to the engine's
   actual tuning. The gate is the only place both numbers exist, and
   re-referencing is the same translation it already performs for the analysis
   window.

   What remains a fault, correctly, is the crystal moving *away* from the
   tuning — a real detuning that grows with temperature.

   **Drift during a session is still not followed.** A crystal that warms up
   and walks off the rate it was tuned to is detected and banded, not chased.
   That one genuinely does need a radio that warms up: chasing it means
   swapping IIR coefficients under live filter state, which rings.

3b. ~~A source that cannot report its rate until it has streamed~~ — **done**,
   and it was not the same problem as drift, which is why it did not need the
   radio.

   Tuning at construction assumed the source could answer *before it had
   streamed*. A source that knows its own crystal can. A BLE source measuring
   its rate from packet arrival times cannot: it would report its nominal at
   construction and learn the truth some seconds later — by which point the
   engine was built, and the gate would band the difference as drift and
   suppress every frame. Exactly the failure step 3 removed, re-entering
   through the door the radio walks in by.

   The fix has three parts.

   `EegSource.rateMeasured` says whether `effectiveSampleRateHz` is a
   measurement or a nominal standing in for one — the same distinction
   `SignalQuality.contactMeasured` already draws, and needed for the same
   reason: without it the session cannot tell *this device runs at 256 Hz*
   from *this device has not looked yet*, and those two want opposite
   behaviour.

   `SimulatedEegSource.measureRateAfter` models it, which was the last fault
   the simulator could not express. The crystal is off from the very first
   sample — the pump runs off the true rate throughout — while the *reported*
   rate stays nominal until enough has been streamed. A simulator that also
   slowed its delivery to match the nominal it was claiming would agree with
   itself and with nothing else, which is the same trap the drift lever
   already avoids.

   `KoreSession` rebuilds the analysis when the measurement lands. **Rebuilds,
   not retunes** — and that is what makes this cheap where following drift is
   not. A fresh engine starts with an empty ring, so it cannot emit a frame
   until a full window has arrived at the new tuning; there is no
   discontinuity to settle because there is nothing on the far side of one, and
   so no `SignalQualityGate.contaminate` is needed. It happens at most once,
   and only before a baseline exists. A measurement arriving after calibration
   is refused rather than honoured: rebuilding then would either discard a
   capture the user waited fifteen seconds for, or keep one taken through a
   misplaced notch. Refusing degrades to banding the difference as drift, which
   is the pre-existing behaviour and is honest rather than silent. A source
   measures its rate in seconds and calibration takes fifteen, so arriving that
   late is not the case this is for.

   One consequence worth noting: the profile loaded from disk is now held as
   well as adopted, because a rebuilt index with a fresh profile would silently
   drop the user's own thresholds and read as a first-ever session.

   **What this leaves for step 4:** nothing about rates. A BLE source may
   report its crystal whenever it can, including never, and the session copes.

4. The radio. **The Dart half is done; the Kotlin host is not.**

   The split is the useful part, and it is what makes any of this checkable
   before there is a patch. Everything that can be got wrong in a way nobody
   notices is in Dart — the link state machine, gap counting, rate measurement,
   quality reporting — and all of it runs on the host VM against a fake
   channel. What is left below the channel is scan, connect, subscribe,
   forward bytes: the part a device either does or does not do, and the part
   no test on this machine could tell the truth about anyway.

   `lib/services/kore_ble.dart` is the channel, copied from
   `kore_platform.dart` deliberately — one `MethodChannel` out for commands,
   one `EventChannel` in for notifications and link transitions, nothing in
   `pubspec.yaml`, and `InertKoreBle` everywhere there is no host so the
   desktop build carries no conditionals. Two channels rather than one is the
   only departure: notifications arrive at the packet rate and carry binary
   payloads, and an `EventChannel` is a stream in that direction rather than a
   round trip with a reply nobody reads. Payloads and transitions share the
   stream so they stay *ordered* — a `reconnecting` overtaking the last packets
   before a drop would clear the sample index while packets from the old stream
   were still in flight.

   `lib/sources/ble_eeg_source.dart` is the source. `createEegSource()` is
   `createDspEngine()` in a different costume: BLE if the platform has one,
   simulated otherwise. The difference is what the fallback *means* — a missing
   native DSP costs speed, a missing radio costs the measurement — so this
   fallback is never silent, and `demo` returning null is what makes the demo
   panel vanish on a real patch instead of shipping a "Simulate detached
   electrode" button to somebody wearing one.

   **The wire format had to be replaced, and that is the finding.**
   `EEGSample.fromBLEBytes` pinned a per-sample format before there was
   firmware, which was the right instinct — but it predates steps 1 and 2 and
   could not carry what the widened seam asks for. A notification has to report
   where its samples sat in the device's own stream, because `SampleBlock`
   takes `firstSampleIndex` so a gap is *counted* rather than guessed, and it
   has to report per-pad contact, because nothing in the DSP can recover that:
   a detached electrode produces a genuinely elevated theta/alpha ratio rather
   than silence. Neither is a property of one sample, so neither had anywhere
   to go. `KorePacket` is the replacement, and the old pair is deleted — it had
   no caller and, contrary to its own doc comment, no test, so it was not a
   pinned contract but a second answer for a firmware author to find beside the
   real one.

   A packet that cannot be trusted is refused whole rather than decoded
   partway: a short block that looks complete is invisible downstream, and the
   *next* packet reports the gap exactly through its own index.

   **What remains:** `android/.../KoreBlePlugin.kt`, and a patch to point it
   at. Nothing on this machine can verify that half, and no test here should
   be read as claiming otherwise.

Steps 1 to 3 are entirely app-side, are testable today, and are the difference
between hardware being a drop-in and hardware being a rewrite — which is the
claim the seam exists to make true. All three are now done, and nothing left
on this list can be built without a radio.
