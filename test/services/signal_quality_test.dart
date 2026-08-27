import 'package:flutter_test/flutter_test.dart';
import 'package:kore/services/signal_quality.dart';

SignalQuality _q({
  double? contact = 1.0,
  int dropped = 0,
  double measuredRateHz = 256.0,
  double referenceRateHz = 256.0,
}) =>
    SignalQuality(
      contact: contact,
      droppedSamples: dropped,
      measuredRateHz: measuredRateHz,
      referenceRateHz: referenceRateHz,
    );

void main() {
  group('contact', () {
    test('a well-seated electrode is good and has nothing to report', () {
      final q = _q(contact: 0.95);
      expect(q.level, SignalQualityLevel.good);
      expect(q.faults, isEmpty);
      expect(q.isUsable, isTrue);
    });

    test('a loose electrode is degraded, and still a reading', () {
      final q = _q(contact: 0.45);
      expect(q.level, SignalQualityLevel.degraded);
      expect(q.faults, {SignalFault.poorContact});
      expect(q.isUsable, isTrue,
          reason: 'a slipping band costs confidence, not the reading');
    });

    test('a badly seated electrode is unusable without being called off', () {
      final q = _q(contact: 0.25);
      expect(q.level, SignalQualityLevel.unusable);
      expect(q.faults, {SignalFault.poorContact},
          reason: 'telling a user to reattach an attached electrode is noise');
    });

    test('a detached electrode is named, because the fix is different', () {
      final q = _q(contact: 0.02);
      expect(q.level, SignalQualityLevel.unusable);
      expect(q.faults, {SignalFault.electrodeDetached});
    });

    test('an unmeasurable contact is not a fault, and not a clean bill', () {
      final q = _q(contact: null);
      expect(q.level, SignalQualityLevel.good,
          reason: 'absence of evidence is not evidence of a fault');
      expect(q.faults, isEmpty);
      expect(q.contactMeasured, isFalse,
          reason: 'nothing may claim the contact was verified');
    });
  });

  group('dropout', () {
    test('a single lost sample disqualifies the block', () {
      final q = _q(dropped: 1);
      expect(q.level, SignalQualityLevel.unusable);
      expect(q.faults, {SignalFault.dropout});
    });

    test('no gap, no fault', () {
      expect(_q(dropped: 0).faults, isEmpty);
    });
  });

  group('sample rate drift', () {
    test('a crystal inside tolerance passes', () {
      final q = _q(measuredRateHz: 256.0 * 1.005);
      expect(q.level, SignalQualityLevel.good);
      expect(q.faults, isEmpty);
      expect(q.rateDriftFraction, closeTo(0.005, 1e-9));
    });

    test('past a percent the notch is detuned and the reading is degraded', () {
      final q = _q(measuredRateHz: 256.0 * 1.015);
      expect(q.level, SignalQualityLevel.degraded);
      expect(q.faults, {SignalFault.sampleRateDrift});
    });

    test('a clock this far off describes a different frame rate entirely', () {
      final q = _q(measuredRateHz: 256.0 * 0.96);
      expect(q.level, SignalQualityLevel.unusable);
      expect(q.faults, {SignalFault.sampleRateDrift});
    });

    test('a source that reports no rate cannot be shown to drift', () {
      expect(SignalQuality.unreported.rateDriftFraction, 0);
      expect(SignalQuality.unreported.level, SignalQualityLevel.good);
      expect(SignalQuality.unreported.faults, isEmpty);
    });
  });

  test('worst fault wins, and every fault is still named', () {
    final q = _q(contact: 0.45, dropped: 8, measuredRateHz: 256.0 * 1.015);
    expect(q.level, SignalQualityLevel.unusable,
        reason: 'the dropout is the worst of the three');
    expect(
        q.faults,
        {
          SignalFault.poorContact,
          SignalFault.dropout,
          SignalFault.sampleRateDrift,
        },
        reason: 'poor contact and a dropout have different fixes');
  });

  test('a pristine source reads clean at whatever rate it runs', () {
    const q = SignalQuality.pristine(250.0);
    expect(q.level, SignalQualityLevel.good);
    expect(q.faults, isEmpty);
    expect(q.rateDriftFraction, 0);
  });
}
