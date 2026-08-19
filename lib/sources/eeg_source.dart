import '../services/eeg_data_stream.dart';
import '../services/signal_quality.dart';

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

  /// The rate the device is actually sampling at, measured rather than
  /// claimed. [samplingRateHz] is the nominal figure it was built to.
  double get effectiveSampleRateHz;

  int get samplingRateHz;

  /// Label shown in the UI, e.g. "Simulated signal". A demo must never imply
  /// hardware that is not attached.
  String get label;

  Future<void> start();

  Future<void> stop();

  void dispose();
}
