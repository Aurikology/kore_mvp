import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/dsp_engine.dart';
import 'package:kore/services/eeg_data_stream.dart';
import 'package:kore/services/signal_quality.dart';
import 'package:kore/session/signal_quality_gate.dart';

/// One block of [n] samples, carrying whatever the source would have said
/// about it. The sample values are irrelevant here - the gate never looks at
/// them, only at how many there were.
SampleBlock _block(
  int n, {
  double? contact = 1.0,
  int dropped = 0,
}) =>
    SampleBlock(
      samples: List<EEGSample>.generate(
        n,
        (_) => EEGSample(timestamp: 0, channels: const [0.0]),
      ),
      firstSampleIndex: 0,
      quality: SignalQuality(
        contact: contact,
        droppedSamples: dropped,
        measuredRateHz: 256,
        nominalRateHz: 256,
      ),
    );

const int _hop = DspConfig.hopSize; // 64 samples, one frame's worth

void main() {
  test('a gate that has seen nothing is not accusing anybody', () {
    final gate = SignalQualityGate();
    expect(gate.isUsable, isTrue);
    expect(gate.isBaselineGrade, isTrue);
    expect(gate.faults, isEmpty);
  });

  test('a gap disqualifies frames until it has left the analysis window', () {
    final gate = SignalQualityGate();
    for (var i = 0; i < 20; i++) {
      gate.observeBlock(_block(_hop));
    }
    expect(gate.isUsable, isTrue);

    gate.observeBlock(_block(_hop, dropped: 32));
    expect(gate.isUsable, isFalse);
    expect(gate.faults, contains(SignalFault.dropout));

    // A full window of clean samples has to pass. The block carrying the gap
    // does not count toward it, so that is windowSize/hop blocks from here.
    const blocksToFlush = DspConfig.windowSize ~/ _hop;
    for (var i = 0; i < blocksToFlush - 1; i++) {
      gate.observeBlock(_block(_hop));
      expect(gate.isUsable, isFalse,
          reason: 'the window still spans the splice after ${i + 1} blocks');
    }
    expect(gate.faults, contains(SignalFault.settling));
    expect(gate.faults, contains(SignalFault.dropout),
        reason: 'settling has to still say what it is settling from');

    gate.observeBlock(_block(_hop));
    expect(gate.isUsable, isTrue);
    expect(gate.faults, isEmpty);
  });

  test('a re-seated electrode is not believed for a full window', () {
    final gate = SignalQualityGate();
    gate.observeBlock(_block(_hop));

    for (var i = 0; i < 8; i++) {
      gate.observeBlock(_block(_hop, contact: 0.0));
    }
    expect(gate.isUsable, isFalse);
    expect(gate.faults, contains(SignalFault.electrodeDetached));

    // Perfect contact from here, but the window is still half artifact.
    gate.observeBlock(_block(_hop, contact: 1.0));
    expect(gate.quality.level, SignalQualityLevel.good,
        reason: 'the source is right about the samples it just sent');
    expect(gate.isUsable, isFalse,
        reason: 'and the window they landed in is still full of the old ones');
    expect(gate.faults,
        containsAll({SignalFault.settling, SignalFault.electrodeDetached}));

    const blocksToFlush = DspConfig.windowSize ~/ _hop;
    for (var i = 1; i < blocksToFlush; i++) {
      gate.observeBlock(_block(_hop, contact: 1.0));
    }
    expect(gate.isUsable, isTrue);
    expect(gate.isBaselineGrade, isTrue);
  });

  test('a condition, unlike an event, passes straight through', () {
    final gate = SignalQualityGate();
    for (var i = 0; i < 20; i++) {
      gate.observeBlock(_block(_hop, contact: 0.45));
    }
    expect(gate.level, SignalQualityLevel.degraded);
    expect(gate.isUsable, isTrue);
    expect(gate.isBaselineGrade, isFalse);
    expect(gate.faults, {SignalFault.poorContact},
        reason: 'a degraded stretch never needs settling out of');
  });

  test('a report with no samples behind it still lands', () {
    final gate = SignalQualityGate();
    for (var i = 0; i < 20; i++) {
      gate.observeBlock(_block(_hop));
    }
    expect(gate.isUsable, isTrue);

    // The shape of a link that dropped: nothing arrives, so nothing would ever
    // update a consumer that only listened to blocks.
    gate.observeQuality(const SignalQuality(
      contact: 0.0,
      measuredRateHz: 256,
      nominalRateHz: 256,
    ));
    expect(gate.isUsable, isFalse);
    expect(gate.faults, contains(SignalFault.electrodeDetached));
  });

  test('reset puts it back to knowing nothing', () {
    final gate = SignalQualityGate();
    gate.observeBlock(_block(_hop, contact: 0.0));
    expect(gate.isUsable, isFalse);

    gate.reset();
    expect(gate.isUsable, isTrue);
    expect(gate.faults, isEmpty);
  });
}
