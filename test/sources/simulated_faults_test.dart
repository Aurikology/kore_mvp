import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/services/eeg_data_stream.dart';
import 'package:kore/services/signal_quality.dart';
import 'package:kore/sources/simulated_eeg_source.dart';

SimulatedEegSource _source(FakeAsync async) =>
    SimulatedEegSource(elapsedMicros: () => async.elapsed.inMicroseconds);

void _advance(FakeAsync async, Duration d) {
  async.elapse(d);
  async.flushMicrotasks();
}

void main() {
  test('a well-seated simulated electrode reports nothing wrong', () {
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(seconds: 2));

      expect(source.quality.level, SignalQualityLevel.good);
      expect(source.quality.faults, isEmpty);
      expect(source.quality.contact, 1.0);
      expect(source.quality.contactMeasured, isTrue);
      expect(source.effectiveSampleRateHz, 256.0);
      source.dispose();
    });
  });

  test('a headband working loose walks the report down, in order', () {
    fakeAsync((async) {
      final source = _source(async);
      final steps = <SignalQuality>[];
      source.qualityUpdates.listen(steps.add);
      source.start();
      _advance(async, const Duration(seconds: 1));

      source.degradeContact(perSecond: 0.1);
      _advance(async, const Duration(seconds: 12));

      // Contact fails gradually, and every stage of it is worth saying out
      // loud: the user can still fix a slipping band, and cannot fix a band
      // they were never told about.
      expect(steps.map((q) => q.level).toList(), [
        SignalQualityLevel.degraded,
        SignalQualityLevel.unusable,
        SignalQualityLevel.unusable,
      ]);
      expect(steps.map((q) => q.faults).toList(), [
        {SignalFault.poorContact},
        {SignalFault.poorContact},
        {SignalFault.electrodeDetached},
      ]);
      expect(source.quality.contact, 0.0);
      source.dispose();
    });
  });

  test('an electrode can be put back on', () {
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(seconds: 1));

      source.detachElectrode();
      expect(source.quality.level, SignalQualityLevel.unusable);

      source.restoreContact();
      expect(source.quality.level, SignalQualityLevel.good);
      expect(source.quality.faults, isEmpty);
      source.dispose();
    });
  });

  test('a lost block leaves a countable hole in the sample index', () {
    fakeAsync((async) {
      final source = _source(async);
      final blocks = <SampleBlock>[];
      source.sampleBlocks.listen(blocks.add);
      source.start();

      _advance(async, const Duration(seconds: 1));
      expect(blocks.length, greaterThan(10));
      for (var i = 1; i < blocks.length; i++) {
        expect(blocks[i].firstSampleIndex,
            blocks[i - 1].firstSampleIndex + blocks[i - 1].length,
            reason: 'an unbroken stream has no holes to count');
      }

      source.dropSamples(200);
      _advance(async, const Duration(seconds: 2));

      final first = blocks.first;
      final last = blocks.last;
      final deviceSpan =
          last.firstSampleIndex + last.length - first.firstSampleIndex;
      final delivered =
          blocks.fold<int>(0, (sum, b) => sum + b.length);

      expect(deviceSpan - delivered, 200,
          reason: 'the device index is what makes a gap exact rather than '
              'inferred from arrival times');
      source.dispose();
    });
  });

  test('a stalled radio reports the dropout while it is delivering nothing',
      () {
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(seconds: 1));

      source.dropSamples(256);
      // Half a second in: still swallowing, so no block has arrived to carry
      // the news, which is exactly why quality also has a stream of its own.
      _advance(async, const Duration(milliseconds: 500));
      expect(source.quality.level, SignalQualityLevel.unusable);
      expect(source.quality.faults, contains(SignalFault.dropout));

      _advance(async, const Duration(seconds: 2));
      expect(source.quality.level, SignalQualityLevel.good,
          reason: 'the source is right about the samples it is sending now');
      source.dispose();
    });
  });

  test('a drifting crystal is reported measured, and actually drifts', () {
    fakeAsync((async) {
      final source = _source(async);
      final blocks = <SampleBlock>[];
      source.sampleBlocks.listen(blocks.add);
      source.start();
      source.setSampleRateError(0.02);
      _advance(async, const Duration(seconds: 4));

      expect(source.effectiveSampleRateHz, closeTo(261.12, 1e-9));
      expect(source.samplingRateHz, 256, reason: 'nominal is unchanged');
      expect(source.quality.level, SignalQualityLevel.degraded);
      expect(source.quality.faults, {SignalFault.sampleRateDrift});

      final delivered = blocks.fold<int>(0, (sum, b) => sum + b.length);
      expect(delivered / 4.0, closeTo(261.12, 2.0),
          reason: 'a simulator that reported drift without producing it '
              'would agree with itself and nothing else');
      source.dispose();
    });
  });
}
