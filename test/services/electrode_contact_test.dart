import 'package:flutter_test/flutter_test.dart';
import 'package:kore/services/signal_quality.dart';

ElectrodeContact _e(String id, double? contact) =>
    ElectrodeContact(id: id, label: id, contact: contact);

SignalQuality _fromPads(List<ElectrodeContact> pads) =>
    SignalQuality.fromElectrodes(
      electrodes: pads,
      measuredRateHz: 256.0,
      nominalRateHz: 256.0,
    );

void main() {
  group('ElectrodeContact banding', () {
    test('a well-seated pad reads good', () {
      expect(_e('left', 0.95).state, ElectrodeContactState.good);
      expect(_e('left', 0.95).needsAttention, isFalse);
      expect(_e('left', 0.95).isMeasured, isTrue);
    });

    test('a loose pad reads weak and is actionable', () {
      expect(_e('left', 0.45).state, ElectrodeContactState.weak);
      expect(_e('left', 0.45).needsAttention, isTrue);
    });

    test('a pad that has come off reads noContact', () {
      expect(_e('left', 0.02).state, ElectrodeContactState.noContact);
      expect(_e('left', 0.02).needsAttention, isTrue);
    });

    test('an unmeasurable pad is unmeasured, never good', () {
      final pad = _e('left', null);
      expect(pad.state, ElectrodeContactState.unmeasured);
      expect(pad.isMeasured, isFalse);
      // The whole point: absence of a measurement must not render as health.
      expect(pad.state, isNot(ElectrodeContactState.good));
      // Nor may it be presented as something the user can act on.
      expect(pad.needsAttention, isFalse);
    });

    test('pads band against the same constants as the aggregate', () {
      expect(_e('a', SignalQuality.kContactGood).state,
          ElectrodeContactState.good);
      expect(_e('a', SignalQuality.kContactGood - 0.01).state,
          ElectrodeContactState.weak);
      expect(_e('a', SignalQuality.kContactDetached - 0.01).state,
          ElectrodeContactState.noContact);
    });
  });

  group('rolling per-electrode contact up', () {
    test('the worst pad sets the aggregate, not the average', () {
      final q = _fromPads([_e('a', 1.0), _e('b', 1.0), _e('c', 0.0)]);
      // Averaging would give 0.67 and read as merely degraded. Worst-wins is
      // what stops three good pads diluting one that has come off.
      expect(q.contact, 0.0);
      expect(q.level, SignalQualityLevel.unusable);
      expect(q.faults, contains(SignalFault.electrodeDetached));
    });

    test('all pads good rolls up to good', () {
      final q = _fromPads([_e('a', 0.9), _e('b', 0.95)]);
      expect(q.contact, 0.9);
      expect(q.level, SignalQualityLevel.good);
      expect(q.faults, isEmpty);
    });

    test('one loose pad degrades without disqualifying', () {
      final q = _fromPads([_e('a', 1.0), _e('b', 0.45)]);
      expect(q.level, SignalQualityLevel.degraded);
      expect(q.faults, {SignalFault.poorContact});
      expect(q.isUsable, isTrue);
    });

    test('unmeasurable pads are skipped, not counted as bad', () {
      final q = _fromPads([_e('a', 0.9), _e('b', null)]);
      // A pad that cannot be measured is not evidence of a fault.
      expect(q.contact, 0.9);
      expect(q.level, SignalQualityLevel.good);
      expect(q.faults, isEmpty);
    });

    test('no measurable pad at all reports unmeasured, not perfect', () {
      final q = _fromPads([_e('a', null), _e('b', null)]);
      expect(q.contact, isNull);
      expect(q.contactMeasured, isFalse);
      // Reads good on purpose - absence of evidence is not evidence of a
      // fault - but contactMeasured is what stops it being sold as health.
      expect(q.level, SignalQualityLevel.good);
    });
  });

  group('naming the pad the user has to fix', () {
    test('worstElectrode names the offender', () {
      final q = _fromPads([_e('left', 0.9), _e('right', 0.2)]);
      expect(q.worstElectrode?.id, 'right');
    });

    test('worstElectrode is null when nothing can be measured', () {
      expect(_fromPads([_e('a', null)]).worstElectrode, isNull);
    });

    test('electrodesNeedingAttention is worst first', () {
      final q = _fromPads([_e('a', 0.5), _e('b', 0.1), _e('c', 1.0)]);
      expect(q.electrodesNeedingAttention.map((e) => e.id), ['b', 'a']);
    });

    test('electrodesNeedingAttention excludes unmeasured pads', () {
      final q = _fromPads([_e('a', 0.1), _e('b', null)]);
      // There is no instruction to give for a pad whose state is unknown.
      expect(q.electrodesNeedingAttention.map((e) => e.id), ['a']);
    });

    test('two bad pads are both listed even though one fault is reported', () {
      final q = _fromPads([_e('a', 0.0), _e('b', 0.45)]);
      // faults collapses to the worst, but the user has two pads to re-seat
      // and the list is what stops the second being forgotten.
      expect(q.electrodesNeedingAttention.map((e) => e.id), ['a', 'b']);
    });
  });

  group('backward compatibility', () {
    test('the scalar constructor carries no per-electrode detail', () {
      const q = SignalQuality(
        contact: 0.45,
        measuredRateHz: 256.0,
        nominalRateHz: 256.0,
      );
      expect(q.hasPerElectrodeContact, isFalse);
      expect(q.electrodes, isEmpty);
      // Empty means "the device did not break it down", not "the pads are
      // fine" - so the scalar verdict must be untouched.
      expect(q.level, SignalQualityLevel.degraded);
      expect(q.faults, {SignalFault.poorContact});
    });

    test('pristine and unreported are unchanged', () {
      const p = SignalQuality.pristine(256.0);
      expect(p.hasPerElectrodeContact, isFalse);
      expect(p.level, SignalQualityLevel.good);
      expect(SignalQuality.unreported.hasPerElectrodeContact, isFalse);
      expect(SignalQuality.unreported.contactMeasured, isFalse);
    });

    test('a per-electrode report reaches the same verdict as its scalar', () {
      final perPad = _fromPads([_e('a', 1.0), _e('b', 0.45)]);
      const scalar = SignalQuality(
        contact: 0.45,
        measuredRateHz: 256.0,
        nominalRateHz: 256.0,
      );
      expect(perPad.level, scalar.level);
      expect(perPad.faults, scalar.faults);
      expect(perPad.contact, scalar.contact);
    });

    test('per-electrode reports still carry dropout and drift', () {
      final q = SignalQuality.fromElectrodes(
        electrodes: [_e('a', 1.0)],
        measuredRateHz: 256.0,
        nominalRateHz: 256.0,
        droppedSamples: 3,
      );
      expect(q.faults, contains(SignalFault.dropout));
      expect(q.isUsable, isFalse);
    });
  });
}
