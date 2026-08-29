import '../services/eeg_data_stream.dart';
import '../services/signal_quality.dart';
import 'demo_controls.dart';
import 'source_link.dart';

/// A source of EEG samples.
///
/// This is the seam that keeps hardware a drop-in rather than a rewrite. The
/// desktop build uses [SimulatedEegSource]; an Android build would add a BLE
/// implementation behind this same interface, and nothing downstream - engine,
/// index, or UI - would change.
///
/// Samples arrive in blocks rather than singly. At 256 Hz a per-sample stream
/// would mean 256 events and 256 widget rebuilds per second; blocks decouple
/// the acquisition rate from the frame rate.
///
/// The interface also describes the link being *unreliable*, which is the part
/// that took longest to admit. A radio on a dry electrode on a moving head
/// loses contact, loses packets, and runs off a crystal that is not exactly
/// 256 Hz - and the failure that matters is not the loud one. A detached
/// electrode reads as strain, so a source that can only say "here are some
/// samples" cannot be defended anywhere downstream. See
/// `docs/signal-quality.md`.
abstract class EegSource {
  Stream<SampleBlock> get sampleBlocks;

  /// The latest quality report, readable synchronously.
  ///
  /// Anything painting a frame needs an answer now, not on the next block.
  SignalQuality get quality;

  /// Quality as it changes, independently of samples arriving.
  ///
  /// A source whose link has dropped emits no blocks at all, so a consumer
  /// that only learned about quality from blocks would hold a stale "good"
  /// forever. That is the one thing a block-carried report cannot express, and
  /// it is why this stream exists alongside it.
  Stream<SignalQuality> get qualityUpdates;

  /// The link as it stands, readable synchronously.
  ///
  /// Same shape as [quality], and for the same reason: a screen painting now
  /// needs an answer now.
  SourceLink get link;

  /// The link as it changes.
  ///
  /// Alongside a synchronous getter rather than instead of it, exactly as
  /// [qualityUpdates] sits alongside [quality] - and for a sharper version of
  /// the same reason. A link that is scanning, connecting, or reconnecting is
  /// producing no blocks at all, so every state on the way to `streaming` is
  /// unobservable from the sample stream. The pairing screen is made entirely
  /// of those states.
  ///
  /// [start] still means what it meant: acquisition is running when its future
  /// completes. This stream is what the user is shown while it has not.
  Stream<SourceLink> get linkUpdates;

  /// The rate the device is actually sampling at, measured rather than
  /// claimed. [samplingRateHz] is the nominal figure it was built to.
  ///
  /// Read [rateMeasured] before treating this as a measurement.
  double get effectiveSampleRateHz;

  /// Whether [effectiveSampleRateHz] is a measurement yet, or still the
  /// nominal figure standing in for one.
  ///
  /// The same distinction [SignalQuality.contactMeasured] draws, and it exists
  /// here for a sharper reason. A source that measures its rate from packet
  /// arrival times - which is what a BLE source is - cannot answer before it
  /// has streamed, and the analysis is built at the moment the session opens.
  /// Without this the session cannot tell "this device genuinely runs at
  /// 256 Hz" from "this device has not looked yet", so it would either refuse
  /// to accommodate any crystal or re-tune itself every time a number moved.
  ///
  /// A source that knows its own crystal - the simulator, or a device that
  /// reports it in a characteristic - returns true from the start, and the
  /// session tunes once and never revisits it.
  bool get rateMeasured;

  int get samplingRateHz;

  /// Label shown in the UI, e.g. "Simulated signal". A demo must never imply
  /// hardware that is not attached.
  String get label;

  /// The simulator's levers, or null on a source that is measuring a real
  /// head.
  ///
  /// Nullable rather than absent so `KoreSession` can hold an [EegSource]
  /// instead of a `SimulatedEegSource` and still drive a demo - and so the
  /// demo panel is off by construction wherever there is nothing to demo.
  /// See [DemoControls].
  DemoControls? get demo;

  Future<void> start();

  Future<void> stop();

  void dispose();
}
