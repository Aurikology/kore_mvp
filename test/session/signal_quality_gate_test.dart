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
  double measuredRateHz = 256,
  double referenceRateHz = 256,
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
        measuredRateHz: measuredRateHz,
        referenceRateHz: referenceRateHz,
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
      referenceRateHz: 256,
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

  group('a gate tuned to a crystal the source calls broken', () {
    // 5% fast. DspConfig.forMeasuredRate accommodates it - well inside the 10%
    // band - so KoreSession tunes the whole analysis to 268.8 Hz. The *source*
    // still compares against its own 256 Hz nominal and reports 5% drift,
    // which is past kRateDriftUnusable, so every block it hands over reads
    // unusable on its own terms.
    const tunedHz = 256.0 * 1.05;
    SignalQualityGate gate() =>
        SignalQualityGate(config: const DspConfig(sampleRateHz: tunedHz));
    SampleBlock accommodated(int n, {double? contact = 1.0, int dropped = 0}) =>
        _block(n,
            contact: contact,
            dropped: dropped,
            measuredRateHz: tunedHz,
            referenceRateHz: 256);

    test('the raw report and the gate genuinely disagree', () {
      // If this stops being true the rest of the group proves nothing.
      final raw = accommodated(_hop).quality;
      expect(raw.isUsable, isFalse, reason: 'the source, against its nominal');
      expect(raw.referencedTo(tunedHz).isUsable, isTrue,
          reason: 'the gate, against what the engine was built for');
    });

    test('its blocks are believed', () {
      final g = gate();
      g.observeBlock(accommodated(_hop));
      expect(g.isUsable, isTrue);
      expect(g.faults, isEmpty);
    });

    test('one dropout does not wedge it for the rest of the session', () {
      // The regression this group exists for. The gate judged frames by its
      // own re-referenced verdict but counted samples toward the settling
      // window using the source's raw one - so on this device no block ever
      // counted, and a single gap left it settling forever: readings withheld,
      // baseline never capturable, and the notice telling the user to press an
      // electrode that was seated perfectly.
      final g = gate();
      g.observeBlock(accommodated(_hop, dropped: 12));
      expect(g.isUsable, isFalse,
          reason: 'the report itself is still the dropout, not yet settling');

      // Exactly one analysis window of clean samples, no more.
      for (var i = 0; i < DspConfig.windowSize ~/ _hop; i++) {
        g.observeBlock(accommodated(_hop));
      }
      expect(g.isSettling, isFalse);
      expect(g.isUsable, isTrue);
      expect(g.faults, isEmpty);
    });

    test('a resume settles in one window rather than never', () {
      final g = gate();
      g.contaminate({SignalFault.settling});
      expect(g.isSettling, isTrue);
      for (var i = 0; i < DspConfig.windowSize ~/ _hop; i++) {
        g.observeBlock(accommodated(_hop));
      }
      expect(g.isSettling, isFalse);
    });

    test('a contaminating block does not credit its own samples back', () {
      // The mirror of the same defect: when the gate calls a block unusable
      // and the source does not, the block that zeroed the counter would
      // immediately add its own length back and cut the settle short.
      final g = SignalQualityGate(config: DspConfig.nominal);
      // Good on the source's terms (referenced to its own 246), unusable on
      // the gate's: 246 is 3.9% off 256, past kRateDriftUnusable of 3%.
      final block = _block(_hop, measuredRateHz: 246.0, referenceRateHz: 246.0);
      expect(block.quality.isUsable, isTrue);
      expect(block.quality.referencedTo(256.0).isUsable, isFalse);

      g.observeBlock(block);
      expect(g.isUsable, isFalse);

      // A full window short of one block must still be settling.
      for (var i = 0; i < (DspConfig.windowSize ~/ _hop) - 1; i++) {
        g.observeBlock(_block(_hop));
      }
      expect(g.isSettling, isTrue,
          reason: 'the contaminating block must not have counted itself');
      g.observeBlock(_block(_hop));
      expect(g.isSettling, isFalse);
    });
  });
}
