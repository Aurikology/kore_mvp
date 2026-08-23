import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/services/signal_quality.dart';
import 'package:kore/sources/simulated_eeg_source.dart';

SimulatedEegSource _source(FakeAsync async, {Map<String, String>? pads}) =>
    SimulatedEegSource(
      elapsedMicros: () => async.elapsed.inMicroseconds,
      padLabels: pads,
    );

void _advance(FakeAsync async, Duration d) {
  async.elapse(d);
  async.flushMicrotasks();
}

ElectrodeContact _pad(SimulatedEegSource s, String id) =>
    s.quality.electrodes.firstWhere((e) => e.id == id);

void main() {
  test('the simulated patch reports each pad by a lay name', () {
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(seconds: 1));

      expect(source.quality.hasPerElectrodeContact, isTrue);
      expect(source.quality.electrodes.map((e) => e.id), ['left', 'right']);
      expect(source.quality.electrodes.map((e) => e.label),
          ['Left pad', 'Right pad']);
      // No clinical 10-20 designators - see the note on padLabels.
      for (final e in source.quality.electrodes) {
        expect(e.label, isNot(matches(RegExp(r'^(FP|T|O|C|P)\d?Z?$'))));
      }
      source.dispose();
    });
  });

  test('one pad coming off leaves the other reading', () {
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(seconds: 1));

      source.detachPad('left');
      _advance(async, const Duration(milliseconds: 100));

      expect(_pad(source, 'left').state, ElectrodeContactState.noContact);
      expect(_pad(source, 'right').state, ElectrodeContactState.good);
      // The verdict is still worst-wins: one pad off is not a measurement.
      expect(source.quality.level, SignalQualityLevel.unusable);
      expect(source.quality.worstElectrode?.id, 'left');
      expect(
          source.quality.electrodesNeedingAttention.map((e) => e.id), ['left']);
      source.dispose();
    });
  });

  test('a second pad slipping is reported even while a first is off', () {
    // The transition-loss case. Neither the aggregate level nor the fault set
    // moves when the second pad crosses out of good - the first pad already
    // pinned both - so a stream keyed on those alone would go silent and a
    // per-pad view would never repaint. The user re-seats one pad and stops.
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(seconds: 1));

      source.detachPad('left');
      _advance(async, const Duration(milliseconds: 100));

      final before = source.quality;
      final emissions = <SignalQuality>[];
      source.qualityUpdates.listen(emissions.add);

      source.setPadContact('right', 0.45);
      _advance(async, const Duration(milliseconds: 100));

      // Precondition: the aggregate genuinely did not move.
      expect(source.quality.level, before.level);
      expect(source.quality.faults, before.faults);
      // But the report still went out, because a pad changed band.
      expect(emissions, isNotEmpty);
      expect(emissions.last.electrodes.map((e) => e.state), [
        ElectrodeContactState.noContact,
        ElectrodeContactState.weak,
      ]);
      expect(source.quality.electrodesNeedingAttention.map((e) => e.id),
          ['left', 'right']);
      source.dispose();
    });
  });

  test('one pad working loose does not drag the others down', () {
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(seconds: 1));

      source.degradePad('left', perSecond: 0.1);
      _advance(async, const Duration(seconds: 6));

      expect(_pad(source, 'left').needsAttention, isTrue);
      expect(_pad(source, 'right').contact, 1.0);
      expect(_pad(source, 'right').state, ElectrodeContactState.good);
      source.dispose();
    });
  });

  test('a pad the device cannot measure is unmeasured, not detached', () {
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(seconds: 1));

      source.setPadContact('left', null);
      _advance(async, const Duration(milliseconds: 100));

      expect(_pad(source, 'left').state, ElectrodeContactState.unmeasured);
      expect(_pad(source, 'left').impedanceKOhm, isNull);
      // Not a fault, and not something to instruct the user about.
      expect(source.quality.faults, isEmpty);
      expect(source.quality.level, SignalQualityLevel.good);
      expect(source.quality.electrodesNeedingAttention, isEmpty);
      // And it must not drag the signal model down as though it were off.
      expect(source.generator.contact, 1.0);
      source.dispose();
    });
  });

  test('an unmeasurable pad does not mask a bad one', () {
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(seconds: 1));

      source.setPadContact('left', null);
      source.detachPad('right');
      _advance(async, const Duration(milliseconds: 100));

      expect(source.quality.level, SignalQualityLevel.unusable);
      expect(source.quality.worstElectrode?.id, 'right');
      source.dispose();
    });
  });

  test('whole-patch controls still move every pad', () {
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(seconds: 1));

      source.detachElectrode();
      _advance(async, const Duration(milliseconds: 100));
      expect(source.quality.electrodes.map((e) => e.state),
          everyElement(ElectrodeContactState.noContact));

      source.restoreContact();
      _advance(async, const Duration(milliseconds: 100));
      expect(source.quality.electrodes.map((e) => e.state),
          everyElement(ElectrodeContactState.good));
      expect(source.quality.contact, 1.0);
      source.dispose();
    });
  });

  test('setting one pad cancels the ramp on that pad only', () {
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(seconds: 1));

      source.degradeContact(perSecond: 0.1);
      _advance(async, const Duration(seconds: 2));
      source.setPadContact('left', 1.0);
      _advance(async, const Duration(seconds: 4));

      // left was pinned and stays put; right kept falling.
      expect(_pad(source, 'left').contact, 1.0);
      expect(_pad(source, 'right').contact, lessThan(0.8));
      source.dispose();
    });
  });

  test('the patch can be given a different set of pads', () {
    fakeAsync((async) {
      final source = _source(async, pads: const {'band': 'Headband'});
      source.start();
      _advance(async, const Duration(seconds: 1));

      expect(source.quality.electrodes.map((e) => e.id), ['band']);
      source.detachPad('band');
      _advance(async, const Duration(milliseconds: 100));
      expect(source.quality.level, SignalQualityLevel.unusable);
      source.dispose();
    });
  });

  test('naming a pad the patch does not have is an error, not a no-op', () {
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(seconds: 1));

      // Silently ignoring it would let a typo in a demo script read as a
      // healthy pad.
      expect(() => source.detachPad('frontal'), throwsArgumentError);
      expect(() => source.degradePad('frontal'), throwsArgumentError);
      source.dispose();
    });
  });
}
