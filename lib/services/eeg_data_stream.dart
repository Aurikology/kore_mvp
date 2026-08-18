import 'dart:math';
import 'dart:typed_data';

/// Full-scale range of the (future) wearable's ADC, in microvolts.
///
/// This was previously 5,000,000 uV - i.e. +/-5 V across an int16, or 2441 uV
/// per LSB. At that scale a realistic 50 uV EEG sample quantised to exactly
/// zero, so the wire format silently destroyed every value it carried.
/// 500 uV full scale gives 0.0153 uV/LSB, comfortably finer than the noise
/// floor of any scalp electrode.
const double kFullScaleMicrovolts = 500.0;

const int _kInt16Max = 32767;

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

  /// Wire format: `[sampleCount u16][channelCount u8][ch0 i16]...[chN i16]`,
  /// little-endian throughout.
  ///
  /// Nothing in the desktop build calls this yet - there is no radio. It is
  /// the contract the firmware will have to meet, and it is unit-tested so
  /// that contract is pinned down before hardware exists.
  factory EEGSample.fromBLEBytes(Uint8List bytes, int timestamp) {
    if (bytes.length < 3) {
      return EEGSample(timestamp: timestamp, channels: [], rawBytes: bytes);
    }

    // Respect offsetInBytes: a Uint8List can be a view into a larger buffer,
    // and ByteData.view(bytes.buffer) alone would silently read from offset 0
    // of the backing store instead of the start of this list.
    final byteData =
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
    final channelCount = byteData.getUint8(2);

    final channels = <double>[];
    var offset = 3;
    for (var ch = 0; ch < channelCount && offset + 1 < bytes.length; ch++) {
      final rawValue = byteData.getInt16(offset, Endian.little);
      channels.add((rawValue / _kInt16Max) * kFullScaleMicrovolts);
      offset += 2;
    }

    return EEGSample(
      timestamp: timestamp,
      channels: channels,
      rawBytes: bytes,
    );
  }

  Uint8List toBLEBytes() {
    final data = ByteData(3 + channels.length * 2);
    data.setUint16(0, 1, Endian.little);
    data.setUint8(2, channels.length);

    var offset = 3;
    for (final uv in channels) {
      final raw = ((uv / kFullScaleMicrovolts) * _kInt16Max)
          .round()
          .clamp(-_kInt16Max, _kInt16Max);
      data.setInt16(offset, raw, Endian.little);
      offset += 2;
    }

    return data.buffer.asUint8List(0, offset);
  }

  @override
  String toString() {
    final channelStr = channels.map((v) => v.toStringAsFixed(2)).join(', ');
    return 'EEGSample(ts=$timestamp, channels=[$channelStr] uV)';
  }
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
