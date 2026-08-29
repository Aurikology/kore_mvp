import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/services/kore_ble.dart';
import 'package:kore/sources/eeg_source_factory.dart';
import 'package:kore/sources/simulated_eeg_source.dart';

/// Push one message up the host's event stream, exactly as the Kotlin side
/// will once it exists.
Future<void> _hostSends(Object? payload) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    AndroidKoreBle.stream.name,
    const StandardMethodCodec().encodeSuccessEnvelope(payload),
    (_) {},
  );
}

/// Push an error up the host's event stream.
Future<void> _hostErrors(String code, String message) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    AndroidKoreBle.stream.name,
    const StandardMethodCodec().encodeErrorEnvelope(code: code, message: message),
    (_) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('there is no Android host yet, and the app must know it', () {
    test('the flag says so, in one place, by name', () {
      // MainActivity.kt registers `kore/platform` and nothing else. Flipping
      // this without the Kotlin would give every Android build a BleEegSource
      // wired to nothing: no crash, no log line, just a pairing screen that
      // scans forever.
      expect(kAndroidBleHostInstalled, isFalse);
    });

    test('createKoreBle reports itself unsupported', () {
      final ble = createKoreBle();
      addTearDown(ble.dispose);
      expect(ble.isSupported, isFalse);
    });

    test('createEegSource therefore chooses the simulator', () {
      // The headline behaviour of the factory, and the thing that keeps the
      // app working while half of step 4 is outstanding.
      final source = createEegSource();
      addTearDown(source.dispose);
      expect(source, isA<SimulatedEegSource>());
      expect(source.label, 'Simulated signal',
          reason: 'the fallback is never silent - a missing radio costs the '
              'measurement, unlike a missing native DSP');
      expect(source.demo, isNotNull, reason: 'so the demo panel appears');
    });
  });

  group('the inert channel', () {
    test('every call succeeds and nothing arrives', () async {
      const ble = InertKoreBle();
      // Succeeding rather than throwing is the whole point: a caller that had
      // to guard each call would grow the platform conditional in five places.
      await ble.startScan();
      await ble.disconnect();
      expect(await ble.packets.isEmpty, isTrue);
      expect(await ble.events.isEmpty, isTrue);
      expect(ble.isSupported, isFalse);
      ble.dispose();
    });
  });

  group('BleLinkEvent decoding', () {
    test('every state the host can name round trips', () {
      for (final state in BleLinkState.values) {
        expect(BleLinkEvent.fromMap({'state': state.name})?.state, state);
      }
    });

    test('a name and a battery are carried through', () {
      final event = BleLinkEvent.fromMap(
          {'state': 'streaming', 'name': 'KORE-01', 'battery': 73})!;
      expect(event.deviceName, 'KORE-01');
      expect(event.batteryPercent, 73);
    });

    test('an absent name means unchanged, not anonymous', () {
      expect(BleLinkEvent.fromMap({'state': 'reconnecting'})?.deviceName, isNull);
    });

    test('a failure sentence is carried, for the screen to show', () {
      expect(
          BleLinkEvent.fromMap(
              {'state': 'failed', 'failure': 'Bluetooth is turned off'})?.failure,
          'Bluetooth is turned off');
    });

    test('anything unrecognised is refused rather than guessed at', () {
      for (final junk in <Object?>[
        null,
        'streaming',
        42,
        <String, Object?>{},
        {'state': null},
        {'state': 7},
        {'state': 'STREAMING'},
        {'state': 'teleporting'},
      ]) {
        expect(BleLinkEvent.fromMap(junk), isNull, reason: '$junk');
      }
    });

    test('a battery outside 0-100 is dropped', () {
      for (final raw in [-1, 101, 255]) {
        expect(
            BleLinkEvent.fromMap({'state': 'streaming', 'battery': raw})
                ?.batteryPercent,
            isNull,
            reason: '$raw');
      }
      expect(
          BleLinkEvent.fromMap({'state': 'streaming', 'battery': 0})
              ?.batteryPercent,
          0);
    });

    test('a battery of the wrong type is dropped, not crashed on', () {
      expect(
          BleLinkEvent.fromMap({'state': 'streaming', 'battery': '80'})
              ?.batteryPercent,
          isNull);
    });
  });

  group('the Android channel, driven end to end with no device', () {
    late AndroidKoreBle ble;
    late List<MethodCall> commands;

    setUp(() {
      commands = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidKoreBle.commands, (call) async {
        commands.add(call);
        return null;
      });
      ble = AndroidKoreBle();
    });

    tearDown(() {
      ble.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidKoreBle.commands, null);
    });

    test('commands reach the host', () async {
      await ble.startScan();
      await ble.disconnect();
      expect(commands.map((c) => c.method), ['startScan', 'disconnect']);
    });

    test('a host with no such method degrades rather than throwing', () async {
      // A staged rollout puts a Dart half that knows about a method on top of
      // an APK that does not implement it. That is a normal condition, and it
      // must not take down the frame that called it.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidKoreBle.commands, null);
      await expectLater(ble.startScan(), completes);
    });

    test('a host that fails a call degrades too', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidKoreBle.commands, (call) async {
        throw PlatformException(code: 'BLE_OFF', message: 'Bluetooth is off');
      });
      await expectLater(ble.startScan(), completes);
    });

    test('bytes go to packets and maps go to events, off one stream', () async {
      final packets = <Uint8List>[];
      final events = <BleLinkState>[];
      ble.packets.listen(packets.add);
      ble.events.listen((e) => events.add(e.state));

      await _hostSends(Uint8List.fromList([1, 2, 3]));
      await _hostSends({'state': 'connecting', 'name': 'KORE-01'});
      await _hostSends(Uint8List.fromList([4, 5]));
      await _hostSends({'state': 'streaming'});
      await Future<void>.delayed(Duration.zero);

      expect(packets.map((p) => p.length), [3, 2]);
      expect(events, [BleLinkState.connecting, BleLinkState.streaming]);
    });

    test('ordering between payloads and transitions is preserved', () async {
      // Load-bearing, and the reason they share a stream. A `reconnecting`
      // that overtook the last packets before a drop would clear the sample
      // index while packets from the old stream were still in flight, and the
      // first packet after it would be differenced against nothing.
      final order = <String>[];
      ble.packets.listen((_) => order.add('packet'));
      ble.events.listen((_) => order.add('event'));

      await _hostSends(Uint8List.fromList([1]));
      await _hostSends(Uint8List.fromList([2]));
      await _hostSends({'state': 'reconnecting'});
      await _hostSends(Uint8List.fromList([3]));
      await Future<void>.delayed(Duration.zero);

      expect(order, ['packet', 'packet', 'event', 'packet']);
    });

    test('an unreadable message is dropped, not turned into a state', () async {
      final events = <BleLinkState>[];
      ble.events.listen((e) => events.add(e.state));

      await _hostSends({'state': 'teleporting'});
      await _hostSends('not a map');
      await _hostSends(null);
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
    });

    test('a stream error becomes a link failure the user can be shown',
        () async {
      // The host's stream failing is a link failure, not an app failure. It
      // has to arrive as one, or the pairing screen waits forever for a device
      // that is never coming.
      final events = <BleLinkEvent>[];
      ble.events.listen(events.add);

      await _hostErrors('BLE_OFF', 'Bluetooth is turned off');
      await Future<void>.delayed(Duration.zero);

      expect(events.single.state, BleLinkState.failed);
      expect(events.single.failure, 'Bluetooth is turned off');
    });

    test('dispose is safe, and nothing arrives afterwards', () async {
      final packets = <Uint8List>[];
      ble.packets.listen(packets.add);
      ble.dispose();

      await _hostSends(Uint8List.fromList([1, 2, 3]));
      await Future<void>.delayed(Duration.zero);
      expect(packets, isEmpty);

      // Re-disposed in tearDown; a second dispose must not throw.
      expect(ble.dispose, returnsNormally);
    });
  });
}
