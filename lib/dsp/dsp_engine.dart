import 'band_powers.dart';

/// Analysis constants, shared by every [DspEngine] implementation so the Dart
/// and native paths cannot silently drift apart.
class DspConfig {
  static const double sampleRateHz = 256.0;

  /// Analysis window: 512 samples = 2.0 s, giving exactly 0.5 Hz bin spacing.
  static const int windowSize = 512;

  /// Hop between frames: 64 samples = 0.25 s, i.e. 4 frames per second.
  static const int hopSize = 64;

  static const double mainsHz = 60.0;
  static const double mainsQ = 20.0;

  /// Bin indices, inclusive. At 0.5 Hz/bin: theta 4.0-7.5 Hz, alpha 8.0-12.0
  /// Hz. The split at bin 16 means no bin is counted in both bands.
  static const int thetaBinLo = 8;
  static const int thetaBinHi = 15;
  static const int alphaBinLo = 16;
  static const int alphaBinHi = 24;

  static const double framesPerSecond = sampleRateHz / hopSize; // 4.0
}

/// A streaming EEG signal processor.
///
/// Two implementations exist behind this interface: a pure-Dart reference
/// ([DartDspEngine]) and a C++/FFI port. They implement the identical
/// algorithm, so the app degrades to Dart without any visible difference if
/// the native library is unavailable.
abstract class DspEngine {
  /// Feed a block of samples in microvolts. Blocks rather than single samples
  /// so the native path can cross the FFI boundary once per block.
  void pushBlock(List<double> microvolts);

  /// Returns the most recently completed analysis frame and clears it, or
  /// null if no new frame is ready. Poll after each [pushBlock].
  BandPowers? takeFrame();

  /// The most recent filtered sample, for waveform display.
  double get lastFiltered;

  /// Human-readable backend name, surfaced in the UI so a demo never
  /// overclaims which path is actually running.
  String get backendLabel;

  void reset();

  void dispose();
}
