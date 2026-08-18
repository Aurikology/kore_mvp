import '../services/eeg_data_stream.dart';

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
abstract class EegSource {
  Stream<List<EEGSample>> get sampleBlocks;

  int get samplingRateHz;

  /// Label shown in the UI, e.g. "Simulated signal". A demo must never imply
  /// hardware that is not attached.
  String get label;

  Future<void> start();

  Future<void> stop();

  void dispose();
}
