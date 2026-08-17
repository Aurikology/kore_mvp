import 'dart:typed_data';
import 'dart:math';

/// Represents a single EEG sample from the wearable device
class EEGSample {
  /// Timestamp of the sample in milliseconds since epoch
  final int timestamp;

  /// Raw EEG values in microvolts, indexed by channel
  final List<double> channels;

  /// Raw bytes from the BLE characteristic (for protocol debugging)
  final Uint8List? rawBytes;

  EEGSample({
    required this.timestamp,
    required this.channels,
    this.rawBytes,
  });

  /// Parse EEG sample from BLE characteristic value
  /// Expected format: [sample_count(2B)][channel_count(1B)][ch0_sample_16bit]...[chN_sample_16bit]
  factory EEGSample.fromBLEBytes(Uint8List bytes, int timestamp) {
    if (bytes.length < 3) {
      return EEGSample(
        timestamp: timestamp,
        channels: [],
        rawBytes: bytes,
      );
    }

    final byteData = ByteData.view(bytes.buffer);
    final sampleCount = byteData.getUint16(0, Endian.little);
    final channelCount = byteData.getUint8(2);

    final channels = <double>[];
    int offset = 3;

    for (int ch = 0; ch < channelCount && offset + 1 < bytes.length; ch++) {
      final rawValue = byteData.getInt16(offset, Endian.little);
      // Convert to microvolts (assume 12-bit ADC, ±5V range)
      final microvolts = (rawValue / 2048.0) * 5000000.0;
      channels.add(microvolts);
      offset += 2;
    }

    return EEGSample(
      timestamp: timestamp,
      channels: channels,
      rawBytes: bytes,
    );
  }

  /// Serialize to BLE characteristic format
  Uint8List toBLEBytes() {
    final bytes = BytesBuilder();

    // Write sample count (just use 1 for single sample)
    final data = ByteData(3 + channels.length * 2);
    data.setUint16(0, 1, Endian.little);
    data.setUint8(2, channels.length);

    int offset = 3;
    for (final uv in channels) {
      // Convert from microvolts back to 12-bit ADC value
      final rawValue = ((uv / 5000000.0) * 2048.0).toInt().clamp(-32768, 32767);
      data.setInt16(offset, rawValue, Endian.little);
      offset += 2;
    }

    return data.buffer.asUint8List(0, offset);
  }

  @override
  String toString() {
    final channelStr = channels.map((v) => v.toStringAsFixed(2)).join(', ');
    return 'EEGSample(ts=$timestamp, channels=[$channelStr] µV)';
  }
}

/// Generator for simulated EEG data at 256 Hz
class DummyEEGGenerator {
  final Random _random = Random();
  final int _sampleRate = 256; // Hz
  final int _channelCount;
  final double _noiseAmplitude; // µV
  final double _signalAmplitude; // µV

  int _sampleIndex = 0;

  DummyEEGGenerator({
    int channelCount = 2,
    double noiseAmplitude = 10.0,
    double signalAmplitude = 50.0,
  })  : _channelCount = channelCount,
        _noiseAmplitude = noiseAmplitude,
        _signalAmplitude = signalAmplitude;

  /// Generate next EEG sample
  EEGSample getNextSample() {
    final now = DateTime.now().millisecondsSinceEpoch;

    final channels = <double>[];

    // Generate channels with phase shifts for diversity
    for (int ch = 0; ch < _channelCount; ch++) {
      // Base sine wave at ~10 Hz (alpha band simulation)
      final phase = (2 * pi * _sampleIndex * 10.0) / _sampleRate;
      final phaseShift = (ch * pi / 2); // 90° phase shift per channel

      // Signal with phase shift
      final signal = _signalAmplitude * sin(phase + phaseShift);

      // Add 60 Hz noise (power line interference simulation)
      final noisePhase = (2 * pi * _sampleIndex * 60.0) / _sampleRate;
      final noise =
          (_noiseAmplitude * 0.3) * sin(noisePhase) + // 60 Hz component
              (_random.nextDouble() - 0.5) * _noiseAmplitude; // White noise

      channels.add(signal + noise);
    }

    _sampleIndex++;

    return EEGSample(
      timestamp: now,
      channels: channels,
    );
  }

  /// Reset sample counter
  void reset() {
    _sampleIndex = 0;
  }

  /// Get current sampling interval in milliseconds (should be ~3.9 ms for 256 Hz)
  double getSamplingIntervalMs() {
    return 1000.0 / _sampleRate;
  }
}

/// Stream controller wrapper for EEG data
class EEGDataStream {
  static const int _samplingRateHz = 256;
  static const int _samplingIntervalMs = 1000 ~/ _samplingRateHz; // ~3.9 ms

  final DummyEEGGenerator _generator;
  int _lastTimestamp = DateTime.now().millisecondsSinceEpoch;

  EEGDataStream({int channelCount = 2})
      : _generator = DummyEEGGenerator(channelCount: channelCount);

  /// Get next sample, respecting timing constraints
  EEGSample getNextSample() {
    final sample = _generator.getNextSample();

    // Update last timestamp
    _lastTimestamp = sample.timestamp;

    return sample;
  }

  /// Get sample rate in Hz
  int getSamplingRate() => _samplingRateHz;

  /// Get expected interval between samples in ms
  int getSamplingIntervalMs() => _samplingIntervalMs;

  /// Reset the generator
  void reset() {
    _generator.reset();
    _lastTimestamp = DateTime.now().millisecondsSinceEpoch;
  }
}
