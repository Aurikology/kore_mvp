import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/services/eeg_data_stream.dart';
import 'package:kore/services/signal_quality.dart';
import 'package:kore/sources/simulated_eeg_source.dart';
import 'package:kore/sources/source_link.dart';

SimulatedEegSource _source(
  FakeAsync async, {
  Duration scan = Duration.zero,
  Duration connect = Duration.zero,
  int? battery = 87,
}) =>
    SimulatedEegSource(
      elapsedMicros: () => async.elapsed.inMicroseconds,
      scanDuration: scan,
      connectDuration: connect,
      batteryPercent: battery,
    );

void _advance(FakeAsync async, Duration d) {
  async.elapse(d);
  async.flushMicrotasks();
}

void main() {
  test('a source that has not been started has no link', () {
    fakeAsync((async) {
      final source = _source(async);
      expect(source.link.state, SourceLinkState.idle);
      expect(source.link.patch, isNull);
      expect(source.link.isLive, isFalse);
      source.dispose();
    });
  });

  test('start walks scanning -> connecting -> streaming, in that order', () {
    fakeAsync((async) {
      final source = _source(async,
          scan: const Duration(milliseconds: 400),
          connect: const Duration(milliseconds: 300));
      final seen = <SourceLinkState>[];
      source.linkUpdates.listen((l) => seen.add(l.state));

      source.start();
      _advance(async, const Duration(milliseconds: 100));
      expect(seen, [SourceLinkState.scanning],
          reason: 'nothing is known about the device yet');
      expect(source.link.patch, isNull);

      _advance(async, const Duration(milliseconds: 400));
      expect(seen.last, SourceLinkState.connecting);
      expect(source.link.patch?.name, 'Simulated patch',
          reason: 'the device is named as soon as it is found');

      _advance(async, const Duration(milliseconds: 400));
      expect(seen, [
        SourceLinkState.scanning,
        SourceLinkState.connecting,
        SourceLinkState.streaming,
      ]);
      source.dispose();
    });
  });

  test('with no delays configured the sequence still publishes every state',
      () {
    fakeAsync((async) {
      final source = _source(async);
      final seen = <SourceLinkState>[];
      source.linkUpdates.listen((l) => seen.add(l.state));

      source.start();
      _advance(async, const Duration(milliseconds: 1));

      expect(seen, [
        SourceLinkState.scanning,
        SourceLinkState.connecting,
        SourceLinkState.streaming,
      ], reason: 'instant is not the same as invisible');
      source.dispose();
    });
  });

  test('no samples arrive until the link is streaming', () {
    fakeAsync((async) {
      final source = _source(async, scan: const Duration(seconds: 1));
      final blocks = <SampleBlock>[];
      source.sampleBlocks.listen(blocks.add);

      source.start();
      _advance(async, const Duration(milliseconds: 600));
      expect(blocks, isEmpty, reason: 'still scanning');

      _advance(async, const Duration(seconds: 1));
      expect(blocks, isNotEmpty);
      source.dispose();
    });
  });

  test('stopping mid-scan abandons the connection instead of arriving late',
      () {
    fakeAsync((async) {
      final source = _source(async, scan: const Duration(seconds: 2));
      source.start();
      _advance(async, const Duration(milliseconds: 500));
      expect(source.link.state, SourceLinkState.scanning);

      source.stop();
      _advance(async, const Duration(seconds: 5));

      expect(source.link.state, SourceLinkState.idle,
          reason: 'a cancelled scan must not connect a minute later');
      source.dispose();
    });
  });

  test('a battery the device cannot report reads as absent, never as full',
      () {
    fakeAsync((async) {
      final source = _source(async, battery: null);
      source.start();
      _advance(async, const Duration(milliseconds: 1));

      final patch = source.link.patch!;
      expect(patch.batteryMeasured, isFalse);
      expect(patch.batteryPercent, isNull);
      expect(patch.batteryLow, isFalse,
          reason: 'absence of a measurement is not a low reading');
      source.dispose();
    });
  });

  test('a low battery is only low when it was actually measured', () {
    fakeAsync((async) {
      final source = _source(async, battery: 9);
      source.start();
      _advance(async, const Duration(milliseconds: 1));
      expect(source.link.patch!.batteryLow, isTrue);
      source.dispose();
    });
  });

  group('a dropped link', () {
    test('stops delivering blocks and says the signal is unusable', () {
      fakeAsync((async) {
        final source = _source(async);
        final blocks = <SampleBlock>[];
        source.sampleBlocks.listen(blocks.add);
        source.start();
        _advance(async, const Duration(seconds: 1));
        expect(blocks, isNotEmpty);

        source.dropLink();
        final delivered = blocks.length;
        _advance(async, const Duration(seconds: 2));

        expect(source.link.state, SourceLinkState.reconnecting);
        expect(blocks.length, delivered, reason: 'nothing arrives during an outage');
        expect(source.quality.level, SignalQualityLevel.unusable);
        expect(source.quality.faults, contains(SignalFault.dropout));
        source.dispose();
      });
    });

    test('keeps the patch on screen while it tries to come back', () {
      fakeAsync((async) {
        final source = _source(async);
        source.start();
        _advance(async, const Duration(milliseconds: 100));
        source.dropLink();

        expect(source.link.patch?.name, 'Simulated patch',
            reason: 'a reconnecting patch has not become an unknown device');
        source.dispose();
      });
    });

    test('leaves a gap on reconnect rather than a splice', () {
      fakeAsync((async) {
        final source = _source(async);
        final blocks = <SampleBlock>[];
        source.sampleBlocks.listen(blocks.add);
        source.start();
        _advance(async, const Duration(seconds: 1));

        final lastBefore = blocks.last;
        final indexBefore =
            lastBefore.firstSampleIndex + lastBefore.samples.length;

        source.dropLink();
        _advance(async, const Duration(seconds: 2));
        source.restoreLink();
        _advance(async, const Duration(milliseconds: 100));

        final first = blocks.last;
        expect(first.firstSampleIndex, greaterThan(indexBefore + 500),
            reason: 'the device kept sampling through the outage, so the '
                'index has to have moved by everything that went missing');
        source.dispose();
      });
    });

    test('recovers cleanly once samples are arriving again', () {
      fakeAsync((async) {
        final source = _source(async);
        source.start();
        _advance(async, const Duration(seconds: 1));
        source.dropLink();
        _advance(async, const Duration(seconds: 1));
        source.restoreLink();
        _advance(async, const Duration(seconds: 1));

        expect(source.link.state, SourceLinkState.streaming);
        expect(source.quality.level, SignalQualityLevel.good);
        expect(source.quality.faults, isEmpty);
        source.dispose();
      });
    });
  });

  test('a failed link carries a reason a user can act on', () {
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(milliseconds: 100));
      source.failLink();

      expect(source.link.state, SourceLinkState.failed);
      expect(source.link.failure, isNotNull);
      expect(source.link.failure, isNotEmpty);
      source.dispose();
    });
  });

  test('the link stream emits transitions, not a value per tick', () {
    fakeAsync((async) {
      final source = _source(async);
      final seen = <SourceLink>[];
      source.linkUpdates.listen(seen.add);

      source.start();
      _advance(async, const Duration(seconds: 3));

      expect(seen.length, 3,
          reason: 'three seconds of streaming is not three seconds of events');
      source.dispose();
    });
  });

  test('the simulated patch names itself as simulated', () {
    fakeAsync((async) {
      final source = _source(async);
      source.start();
      _advance(async, const Duration(milliseconds: 1));

      expect(source.link.patch!.name.toLowerCase(), contains('simulated'));
      expect(source.label.toLowerCase(), contains('simulated'));
      source.dispose();
    });
  });
}
