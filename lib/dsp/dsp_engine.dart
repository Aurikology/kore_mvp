import 'band_powers.dart';

/// The analysis configuration, shared by every [DspEngine] implementation so
/// the Dart and native paths cannot silently drift apart.
///
/// The *geometry* is static and always will be: the window, the hop, the bin
/// edges and the mains notch are design decisions, identical on every device.
/// The *rate* is not. A real crystal runs at 255.7 Hz, or 261 Hz, and moves
/// with temperature - so it arrives from the source at runtime, and everything
/// derived from it is derived per instance.
///
/// That split is the whole point. Reading a 256.0 constant while the device
/// actually sampled at something else detunes the 60 Hz notch, and stretches
/// every duration in the app that is counted in frames rather than seconds.
/// Both used to be true here; see the sample-rate section of
/// `docs/hardware-seam.md`.
class DspConfig {
  /// The rate the analysis geometry was designed against, and the rate every
  /// published figure is quoted at. [nominal] reproduces them exactly.
  static const double nominalSampleRateHz = 256.0;

  /// Analysis window: 512 samples = 2.0 s at the nominal rate, giving exactly
  /// 0.5 Hz bin spacing.
  static const int windowSize = 512;

  /// Hop between frames: 64 samples = 0.25 s at the nominal rate, i.e. 4
  /// frames per second.
  static const int hopSize = 64;

  static const double mainsHz = 60.0;
  static const double mainsQ = 20.0;

  /// Bin indices, inclusive. At 0.5 Hz/bin: theta 4.0-7.5 Hz, alpha 8.0-12.0
  /// Hz. The split at bin 16 means no bin is counted in both bands.
  ///
  /// Indices, not frequencies, and they stay indices at any rate. A bin's
  /// frequency is `k * fs / windowSize`, so the band edges follow the true
  /// rate rather than staying pinned to 4.0 and 8.0 Hz. That is the honest
  /// behaviour and the error is negligible: 2% of rate error moves the alpha
  /// edge by 0.16 Hz, a third of one bin. Pinning the edges instead would mean
  /// a fractional-bin Goertzel, which is a real cost for a shift smaller than
  /// the resolution it would be correcting.
  static const int thetaBinLo = 8;
  static const int thetaBinHi = 15;
  static const int alphaBinLo = 16;
  static const int alphaBinHi = 24;

  /// The widest rate error that is treated as a crystal rather than a fault.
  ///
  /// Deliberately generous. Inside this band a measured rate is *accommodated*
  /// - the filters are built against it and it costs nothing. Outside it, the
  /// number is not a crystal: crystals do not run 10% fast, and building a
  /// 60 Hz notch against a bogus rate puts the notch somewhere arbitrary,
  /// which is worse than the constant it replaced. [forMeasuredRate] falls
  /// back rather than trusting it.
  static const double kMaxRateErrorFraction = 0.10;

  /// The rate this configuration is running at - measured, not claimed.
  final double sampleRateHz;

  const DspConfig({this.sampleRateHz = nominalSampleRateHz});

  /// The configuration the published figures are quoted against. The default
  /// everywhere a rate is not supplied, so a caller that knows nothing about
  /// rates behaves exactly as this code did before rates were a thing.
  static const DspConfig nominal = DspConfig();

  /// A configuration for a rate a source has measured, falling back to
  /// [nominal] for one that cannot be believed.
  ///
  /// Zero, negative, NaN and infinity are the ones that would actually reach
  /// here: a device that has not measured yet, or a division by an elapsed
  /// time of zero. None of them should take the notch with them.
  factory DspConfig.forMeasuredRate(double hz) {
    if (!hz.isFinite || hz <= 0) return nominal;
    final error = (hz - nominalSampleRateHz).abs() / nominalSampleRateHz;
    if (error > kMaxRateErrorFraction) return nominal;
    return DspConfig(sampleRateHz: hz);
  }

  /// Whether this configuration is tuned to something other than the rate the
  /// geometry was designed against. Surfaced so a demo can say so out loud.
  bool get isOffNominal => sampleRateHz != nominalSampleRateHz;

  /// Analysis frames per second: one per [hopSize] samples. 4.0 at the
  /// nominal rate, and not 4.0 at any other - which is the reason nothing may
  /// count frames against a constant.
  double get framesPerSecond => sampleRateHz / hopSize;

  /// Seconds spanned by one analysis window.
  double get windowSeconds => windowSize / sampleRateHz;

  /// Spacing between analysis bins.
  double get binWidthHz => sampleRateHz / windowSize;

  /// Frames covering [seconds], for a constant that means a duration.
  ///
  /// Always at least one: a duration the caller thought worth naming must not
  /// round to a count that disables the thing it gates.
  int framesForSeconds(double seconds) {
    final n = (seconds * framesPerSecond).round();
    return n < 1 ? 1 : n;
  }

  /// The duration [frames] frames actually took.
  Duration framesToDuration(int frames) =>
      Duration(microseconds: (frames * 1e6 / framesPerSecond).round());
}

/// A streaming EEG signal processor.
///
/// Two implementations exist behind this interface: a pure-Dart reference
/// ([DartDspEngine]) and a C++/FFI port. They implement the identical
/// algorithm, so the app degrades to Dart without any visible difference if
/// the native library is unavailable.
abstract class DspEngine {
  /// The configuration this engine was built against.
  ///
  /// On the interface rather than only on the implementations because it is
  /// the rate everything downstream has to agree with. An index counting
  /// frames at 4 Hz against an engine framing at 4.08 Hz is the exact defect
  /// this replaced, and it was invisible because the rate was never something
  /// you could ask an engine for.
  DspConfig get config;

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
