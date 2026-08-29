import 'dart:math';
import 'dart:typed_data';

import 'signal_quality.dart';

/// Full-scale range of the (future) wearable's ADC, in microvolts.
///
/// This was previously 5,000,000 uV - i.e. +/-5 V across an int16, or 2441 uV
/// per LSB. At that scale a realistic 50 uV EEG sample quantised to exactly
/// zero, so the wire format silently destroyed every value it carried.
/// 500 uV full scale gives 0.0153 uV/LSB, comfortably finer than the noise
/// floor of any scalp electrode.
const double kFullScaleMicrovolts = 500.0;

/// A single EEG sample from the wearable.
class EEGSample {
  /// Milliseconds since epoch.
  final int timestamp;

  /// Raw values in microvolts, indexed by channel.
  final List<double> channels;

  /// Raw bytes from the BLE characteristic, kept for protocol debugging.
  final Uint8List? rawBytes;

  EEGSample({
    required this.timestamp,
    required this.channels,
    this.rawBytes,
  });

  /// The wire format lives in [KorePacket], not here.
  ///
  /// There was a `fromBLEBytes`/`toBLEBytes` pair on this class, pinning a
  /// per-sample format before there was firmware. It was right to write one
  /// down early and it is gone now, for two reasons.
  ///
  /// It could not carry what the seam grew to need. A notification has to
  /// report where its samples sat in the device's own stream - `SampleBlock`
  /// takes `firstSampleIndex` so a gap is counted rather than guessed - and
  /// per-pad contact, which nothing in the DSP can recover because a detached
  /// electrode produces a genuinely elevated theta/alpha ratio rather than
  /// silence. Neither is a property of one sample, so neither had anywhere to
  /// go.
  ///
  /// And it had no caller and, contrary to its own doc comment, no test. A
  /// format nobody encodes, nobody decodes and nothing checks is not a pinned
  /// contract; it is a second answer for a firmware author to find next to the
  /// real one.

  @override
  String toString() {
    final channelStr = channels.map((v) => v.toStringAsFixed(2)).join(', ');
    return 'EEGSample(ts=$timestamp, channels=[$channelStr] uV)';
  }
}

/// One delivery from an `EegSource`: samples, where they sat in the device's
/// own stream, and how much the source trusts them.
///
/// Quality rides on the block rather than arriving on a stream of its own
/// because it has to be *attributable*. A separate stream races with the
/// samples, and a race here means a report of good contact getting applied to
/// the block that was taken while the electrode was already off - which is the
/// exact failure the quality path exists to prevent.
class SampleBlock {
  final List<EEGSample> samples;

  /// Device-side index of the first sample in this block, monotonic from the
  /// start of the stream.
  ///
  /// This is what makes a gap countable rather than guessable.
  /// [EEGSample.timestamp] is stamped when the *app* assembled the block, so
  /// it says when the host saw the data and nothing at all about when the
  /// device sampled it.
  final int firstSampleIndex;

  /// The source's report on itself as of this block.
  final SignalQuality quality;

  const SampleBlock({
    required this.samples,
    required this.firstSampleIndex,
    required this.quality,
  });

  int get length => samples.length;

  bool get isEmpty => samples.isEmpty;
}

/// Fixed 10 Hz synthetic EEG - constant amplitude, deterministic phase.
///
/// Kept deliberately unchanged as a test fixture: because it never varies, it
/// is a stable oracle for the DSP. The live demo uses ScenarioEEGGenerator
/// instead, which modulates alpha and theta over time so the index actually
/// moves.
class DummyEEGGenerator {
  final Random _random = Random();
  final int _sampleRate = 256;
  final int _channelCount;
  final double _noiseAmplitude;
  final double _signalAmplitude;

  int _sampleIndex = 0;

  DummyEEGGenerator({
    int channelCount = 2,
    double noiseAmplitude = 10.0,
    double signalAmplitude = 50.0,
  })  : _channelCount = channelCount,
        _noiseAmplitude = noiseAmplitude,
        _signalAmplitude = signalAmplitude;

  EEGSample getNextSample() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final channels = <double>[];

    for (var ch = 0; ch < _channelCount; ch++) {
      final phase = (2 * pi * _sampleIndex * 10.0) / _sampleRate;
      final phaseShift = ch * pi / 2;
      final signal = _signalAmplitude * sin(phase + phaseShift);

      final noisePhase = (2 * pi * _sampleIndex * 60.0) / _sampleRate;
      final noise = (_noiseAmplitude * 0.3) * sin(noisePhase) +
          (_random.nextDouble() - 0.5) * _noiseAmplitude;

      channels.add(signal + noise);
    }

    _sampleIndex++;
    return EEGSample(timestamp: now, channels: channels);
  }

  void reset() => _sampleIndex = 0;

  double getSamplingIntervalMs() => 1000.0 / _sampleRate;
}
