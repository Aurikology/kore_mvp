import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kore/services/ble_packet.dart';
import 'package:kore/services/eeg_data_stream.dart';
import 'package:kore/services/kore_ble.dart';
import 'package:kore/services/signal_quality.dart';
import 'package:kore/sources/ble_eeg_source.dart';
import 'package:kore/sources/source_link.dart';

/// A host that is entirely under the test's control.
///
/// The point of the Dart/Kotlin split is that everything worth getting wrong
/// is above this line, so everything worth testing can be driven from here.
class _FakeBle implements KoreBle {
  final _packets = StreamController<Uint8List>.broadcast();
  final _events = StreamController<BleLinkEvent>.broadcast();

  final List<String> calls = [];
  Object? startScanThrows;
  bool disposed = false;

  @override
  Stream<Uint8List> get packets => _packets.stream;

  @override
  Stream<BleLinkEvent> get events => _events.stream;

  @override
  bool get isSupported => true;

  @override
  Future<void> startScan() async {
    calls.add('startScan');
    final boom = startScanThrows;
    if (boom != null) throw boom;
  }

  @override
  Future<void> disconnect() async => calls.add('disconnect');

  @override
  void dispose() {
    disposed = true;
    _packets.close();
    _events.close();
  }

  void emit(BleLinkEvent event) => _events.add(event);
  void deliver(Uint8List bytes) => _packets.add(bytes);
}

/// A clock the test advances by hand, because a rate measured from arrival
/// times cannot be tested against one that moves on its own.
class _Clock {
  int micros = 0;
  int call() => micros;
  void advance(Duration d) => micros += d.inMicroseconds;
}

Uint8List _payload({
  required int firstSampleIndex,
  int samples = 64,
  List<ElectrodeContact> electrodes = const [],
  int? battery,
}) =>
    KorePacket(
      firstSampleIndex: firstSampleIndex,
      samples: [
        for (var i = 0; i < samples; i++)
          EEGSample(timestamp: 0, channels: [10.0 + i]),
      ],
      electrodes: electrodes,
      batteryPercent: battery,
    ).encode();

/// Let broadcast delivery land.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeBle ble;
  late _Clock clock;
  late BleEegSource source;

  setUp(() {
    ble = _FakeBle();
    clock = _Clock();
    source = BleEegSource(ble: ble, nowMicros: clock.call);
  });

  tearDown(() => source.dispose());

  /// Deliver [packets] contiguous notifications of 64 samples each, at exactly
  /// [rateHz], starting from sample [from].
  Future<int> stream({
    int packets = BleEegSource.kPacketsToMeasureRate + 1,
    double rateHz = 256.0,
    int from = 0,
  }) async {
    var index = from;
    for (var i = 0; i < packets; i++) {
      ble.deliver(_payload(firstSampleIndex: index));
      await _settle();
      index += 64;
      clock.advance(Duration(microseconds: (64 / rateHz * 1e6).round()));
    }
    return index;
  }

  group('the seam is implemented as a seam', () {
    test('a real patch offers no demo levers', () {
      // Off by construction, not behind a flag somebody has to remember to
      // clear before a session with a person wearing hardware.
      expect(source.demo, isNull);
    });

    test('it says what it is, and does not claim to be simulated', () {
      expect(source.label, 'KORE patch');
      expect(source.samplingRateHz, 256);
    });

    test('an inert host reports itself unsupported', () {
      const inert = InertKoreBle();
      expect(inert.isSupported, isFalse);
      expect(BleEegSource(ble: inert).isSupported, isFalse);
    });
  });

  group('link state', () {
    test('start scans, and says so before anything is found', () async {
      final seen = <SourceLinkState>[];
      source.linkUpdates.listen((l) => seen.add(l.state));
      await source.start();
      await _settle();

      expect(ble.calls, ['startScan']);
      expect(source.link.state, SourceLinkState.scanning);
      expect(seen, [SourceLinkState.scanning]);
    });

    test('the whole sequence reaches the pairing screen', () async {
      final seen = <SourceLink>[];
      source.linkUpdates.listen(seen.add);
      await source.start();

      ble.emit(const BleLinkEvent(
          state: BleLinkState.connecting, deviceName: 'KORE-01'));
      ble.emit(const BleLinkEvent(
          state: BleLinkState.streaming, deviceName: 'KORE-01', batteryPercent: 88));
      await _settle();

      expect(seen.map((l) => l.state), [
        SourceLinkState.scanning,
        SourceLinkState.connecting,
        SourceLinkState.streaming,
      ]);
      expect(source.link.patch?.name, 'KORE-01');
      expect(source.link.patch?.batteryPercent, 88);
    });

    test('a reconnect keeps the identity it is reconnecting to', () async {
      await source.start();
      ble.emit(const BleLinkEvent(
          state: BleLinkState.streaming, deviceName: 'KORE-01'));
      await _settle();
      // The host does not re-send a name it has already given.
      ble.emit(const BleLinkEvent(state: BleLinkState.reconnecting));
      await _settle();

      expect(source.link.state, SourceLinkState.reconnecting);
      expect(source.link.patch?.name, 'KORE-01',
          reason: 'a screen that blanked the patch name mid-reconnect would '
              'read as a different device');
    });

    test('a failure carries a sentence the user can be shown', () async {
      await source.start();
      ble.emit(const BleLinkEvent(
          state: BleLinkState.failed, failure: 'Bluetooth is turned off'));
      await _settle();

      expect(source.link.state, SourceLinkState.failed);
      expect(source.link.failure, 'Bluetooth is turned off');
    });

    test('a host that cannot even start scanning fails visibly', () async {
      ble.startScanThrows = StateError('no adapter');
      await source.start();
      await _settle();

      expect(source.link.state, SourceLinkState.failed,
          reason: 'a start() that threw would leave the screen on "scanning" '
              'forever');
      expect(source.link.failure, contains('Could not start scanning'));
    });

    test('stop disconnects and returns to idle', () async {
      await source.start();
      ble.emit(const BleLinkEvent(state: BleLinkState.streaming));
      await _settle();
      await source.stop();

      expect(ble.calls, ['startScan', 'disconnect']);
      expect(source.link.state, SourceLinkState.idle);
    });

    test('an unknown state from the host is refused, not rendered', () {
      // A link state the app does not understand must never be rendered as
      // streaming, which is the only state in which a reading means anything.
      expect(BleLinkEvent.fromMap({'state': 'teleporting'}), isNull);
      expect(BleLinkEvent.fromMap({'state': 42}), isNull);
      expect(BleLinkEvent.fromMap('streaming'), isNull);
      expect(BleLinkEvent.fromMap(null), isNull);
      expect(BleLinkEvent.fromMap({'state': 'streaming'})?.state,
          BleLinkState.streaming);
    });

    test('an out-of-range battery is dropped rather than shown', () {
      expect(
          BleLinkEvent.fromMap({'state': 'streaming', 'battery': 130})
              ?.batteryPercent,
          isNull);
      expect(
          BleLinkEvent.fromMap({'state': 'streaming', 'battery': -1})
              ?.batteryPercent,
          isNull);
    });
  });

  group('samples and gaps', () {
    test('a packet becomes a block carrying its device-side index', () async {
      final blocks = <SampleBlock>[];
      source.sampleBlocks.listen(blocks.add);
      await source.start();

      ble.deliver(_payload(firstSampleIndex: 1024, samples: 64));
      await _settle();

      expect(blocks.single.length, 64);
      expect(blocks.single.firstSampleIndex, 1024);
      expect(blocks.single.quality.droppedSamples, 0);
    });

    test('a lost notification is counted exactly on the next one', () async {
      final blocks = <SampleBlock>[];
      source.sampleBlocks.listen(blocks.add);
      await source.start();

      ble.deliver(_payload(firstSampleIndex: 0, samples: 64));
      await _settle();
      // 64 samples never arrive.
      ble.deliver(_payload(firstSampleIndex: 128, samples: 64));
      await _settle();

      expect(blocks.last.quality.droppedSamples, 64);
      expect(blocks.last.quality.faults, contains(SignalFault.dropout));
      expect(blocks.last.quality.isUsable, isFalse);
    });

    test('an undecodable packet is dropped, and not double-counted', () async {
      // The next packet reports the gap by arithmetic. Guessing a count here
      // would report it twice.
      final blocks = <SampleBlock>[];
      source.sampleBlocks.listen(blocks.add);
      await source.start();

      ble.deliver(_payload(firstSampleIndex: 0, samples: 64));
      await _settle();
      ble.deliver(Uint8List.fromList([1, 2, 3]));
      await _settle();
      expect(blocks.length, 1, reason: 'no block from an unreadable packet');

      ble.deliver(_payload(firstSampleIndex: 128, samples: 64));
      await _settle();
      expect(blocks.last.quality.droppedSamples, 64);
    });

    test('the first packet of a stream reports no gap', () async {
      final blocks = <SampleBlock>[];
      source.sampleBlocks.listen(blocks.add);
      await source.start();

      // Firmware that has been running before the app connected.
      ble.deliver(_payload(firstSampleIndex: 900000, samples: 64));
      await _settle();
      expect(blocks.single.quality.droppedSamples, 0);
    });

    test('a reconnect starts a new stream rather than a vast gap', () async {
      final blocks = <SampleBlock>[];
      source.sampleBlocks.listen(blocks.add);
      await source.start();

      ble.deliver(_payload(firstSampleIndex: 500000, samples: 64));
      await _settle();
      ble.emit(const BleLinkEvent(state: BleLinkState.reconnecting));
      await _settle();
      // The device restarted its counter.
      ble.deliver(_payload(firstSampleIndex: 0, samples: 64));
      await _settle();

      expect(blocks.last.quality.droppedSamples, 0,
          reason: 'differencing across a reconnect would report half a '
              'million samples missing and pin the session in a fault');
    });
  });

  group('quality from the patch', () {
    test('per-pad contact reaches the rollup with the pad named', () async {
      final blocks = <SampleBlock>[];
      source.sampleBlocks.listen(blocks.add);
      await source.start();

      ble.deliver(_payload(firstSampleIndex: 0, electrodes: const [
        ElectrodeContact(id: 'left', label: 'Left pad', contact: 0.95),
        ElectrodeContact(id: 'centre', label: 'Centre pad', contact: 0.08),
      ]));
      await _settle();

      final q = blocks.single.quality;
      expect(q.level, SignalQualityLevel.unusable);
      expect(q.electrodesNeedingAttention.first.label, 'Centre pad');
      expect(q.faults, contains(SignalFault.electrodeDetached));
    });

    test('a patch with no impedance front end is not reported healthy', () async {
      final blocks = <SampleBlock>[];
      source.sampleBlocks.listen(blocks.add);
      await source.start();
      ble.deliver(_payload(firstSampleIndex: 0));
      await _settle();

      expect(blocks.single.quality.contactMeasured, isFalse);
      expect(blocks.single.quality.hasPerElectrodeContact, isFalse);
    });

    test('quality is emitted on a change of verdict, not per packet', () async {
      final updates = <SignalQuality>[];
      source.qualityUpdates.listen(updates.add);
      await source.start();

      for (var i = 0; i < 4; i++) {
        ble.deliver(_payload(firstSampleIndex: i * 64, electrodes: const [
          ElectrodeContact(id: 'left', label: 'Left pad', contact: 0.9),
        ]));
        await _settle();
      }
      expect(updates.length, 1, reason: 'four packets, one verdict');

      ble.deliver(_payload(firstSampleIndex: 4 * 64, electrodes: const [
        ElectrodeContact(id: 'left', label: 'Left pad', contact: 0.05),
      ]));
      await _settle();
      expect(updates.length, 2);
      expect(updates.last.level, SignalQualityLevel.unusable);
    });

    test('battery from a packet updates the patch without a link event',
        () async {
      await source.start();
      ble.emit(const BleLinkEvent(
          state: BleLinkState.streaming, deviceName: 'KORE-01'));
      await _settle();

      ble.deliver(_payload(firstSampleIndex: 0, battery: 41));
      await _settle();

      expect(source.link.patch?.batteryPercent, 41);
      expect(source.link.patch?.name, 'KORE-01');
      expect(source.link.state, SourceLinkState.streaming);
    });
  });

  group('the rate is measured, not claimed', () {
    test('it says it does not know until it has streamed', () async {
      await source.start();
      expect(source.rateMeasured, isFalse);
      expect(source.effectiveSampleRateHz, 256.0,
          reason: 'the nominal, standing in for a measurement');

      // One packet short of the window.
      await stream(packets: BleEegSource.kPacketsToMeasureRate);
      expect(source.rateMeasured, isFalse);
    });

    test('a full window measures the true crystal', () async {
      await source.start();
      await stream(rateHz: 261.12);

      expect(source.rateMeasured, isTrue);
      expect(source.effectiveSampleRateHz, closeTo(261.12, 0.5));
    });

    test('a nominal crystal measures as nominal', () async {
      await source.start();
      await stream(rateHz: 256.0);
      expect(source.effectiveSampleRateHz, closeTo(256.0, 0.5));
    });

    test('a phone that stalled does not become a crystal measurement',
        () async {
      // One long descheduling inside the window makes the arithmetic say the
      // device is running at a fraction of its rate. Believing it would build
      // a 60 Hz notch against a number produced by the operating system.
      await source.start();
      for (var i = 0; i < BleEegSource.kPacketsToMeasureRate + 1; i++) {
        ble.deliver(_payload(firstSampleIndex: i * 64));
        await _settle();
        clock.advance(i == 4
            ? const Duration(seconds: 3)
            : const Duration(milliseconds: 250));
      }

      expect(source.rateMeasured, isFalse,
          reason: 'refused, so the session keeps waiting for a real answer');
      expect(source.effectiveSampleRateHz, 256.0);
    });

    test('a refused window does not poison the next one', () async {
      await source.start();
      // A stall spoils the first window.
      for (var i = 0; i < BleEegSource.kPacketsToMeasureRate + 1; i++) {
        ble.deliver(_payload(firstSampleIndex: i * 64));
        await _settle();
        clock.advance(i == 2
            ? const Duration(seconds: 3)
            : const Duration(milliseconds: 250));
      }
      expect(source.rateMeasured, isFalse);

      // A clean window afterwards must succeed - a stale start time carrying
      // the stall would keep refusing forever.
      final next = (BleEegSource.kPacketsToMeasureRate + 1) * 64;
      await stream(rateHz: 256.0, from: next);
      expect(source.rateMeasured, isTrue);
      expect(source.effectiveSampleRateHz, closeTo(256.0, 1.0));
    });

    test('a lost notification does not read as a slow crystal', () async {
      // The measurement divides samples by wall clock, and the crystal kept
      // ticking through the packets that never arrived. Counting only what
      // survived the air biases the answer low by exactly the loss fraction -
      // one packet in seventeen reads as a 6% slow crystal, which is inside
      // the plausibility band, so it is believed rather than refused, and the
      // session spends its one rebuild tuning a 60 Hz notch to 63.75 Hz.
      // Nothing downstream can catch it: the gate re-references drift to
      // whatever the engine was tuned to, so the error reads as zero drift.
      await source.start();

      var index = 0;
      for (var i = 0; i < BleEegSource.kPacketsToMeasureRate + 2; i++) {
        // Slot 5 is lost on air: the device produced it, the index skips it.
        if (i != 5) ble.deliver(_payload(firstSampleIndex: index));
        await _settle();
        index += 64;
        clock.advance(const Duration(microseconds: 250000));
      }

      expect(source.rateMeasured, isTrue);
      expect(source.effectiveSampleRateHz, closeTo(256.0, 1.0),
          reason: 'the device produced 256 Hz throughout; only the radio '
              'lost some of it');
    });

    test('a packet lost to corruption is counted the same way', () async {
      // An undecodable packet produces no block, so the count of what the
      // device produced has to come from the *next* packet's index. Same
      // arithmetic, different loss mechanism.
      await source.start();

      var index = 0;
      for (var i = 0; i < BleEegSource.kPacketsToMeasureRate + 2; i++) {
        if (i == 5) {
          ble.deliver(Uint8List.fromList([9, 9, 9]));
        } else {
          ble.deliver(_payload(firstSampleIndex: index));
        }
        await _settle();
        index += 64;
        clock.advance(const Duration(microseconds: 250000));
      }

      expect(source.rateMeasured, isTrue);
      expect(source.effectiveSampleRateHz, closeTo(256.0, 1.0));
    });

    test('a reconnect withdraws the measurement rather than keeping it',
        () async {
      await source.start();
      await stream(rateHz: 261.12);
      expect(source.rateMeasured, isTrue);

      ble.emit(const BleLinkEvent(state: BleLinkState.reconnecting));
      await _settle();

      expect(source.rateMeasured, isFalse,
          reason: 'a window straddling a reconnection spans a stretch when no '
              'packets arrived, and would measure a fraction of the true rate');
      expect(source.effectiveSampleRateHz, 256.0);
    });

    test('the measurement counts samples, not packets', () async {
      // A device that coalesces two notifications into one delivered the same
      // number of samples in the same interval, and the rate is unchanged.
      await source.start();
      var index = 0;
      for (var i = 0; i < BleEegSource.kPacketsToMeasureRate + 1; i++) {
        final samples = i.isEven ? 128 : 64;
        ble.deliver(_payload(firstSampleIndex: index, samples: samples));
        await _settle();
        index += samples;
        clock.advance(
            Duration(microseconds: (samples / 256.0 * 1e6).round()));
      }
      expect(source.rateMeasured, isTrue);
      expect(source.effectiveSampleRateHz, closeTo(256.0, 1.0));
    });
  });

  group('lifecycle', () {
    test('a start racing a stop is not stamped back to idle', () async {
      // stop() clears the subscriptions before awaiting the disconnect, so a
      // start() arriving during that await legitimately re-subscribes and
      // re-scans. Publishing idle after the await would stamp it over a link
      // that had just come back, leaving the screen idle while packets flowed.
      await source.start();
      final stopping = source.stop();
      await source.start();
      await stopping;

      expect(source.link.state, SourceLinkState.scanning,
          reason: 'the later start is the live one');
    });

    test('start is idempotent', () async {
      await source.start();
      await source.start();
      expect(ble.calls.where((c) => c == 'startScan').length, 1);
    });
  });

  test('dispose tears the host down with it', () {
    final s = BleEegSource(ble: ble);
    s.dispose();
    expect(ble.disposed, isTrue);
  });
}
