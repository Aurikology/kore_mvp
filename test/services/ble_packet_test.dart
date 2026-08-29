import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kore/services/ble_packet.dart';
import 'package:kore/services/eeg_data_stream.dart';
import 'package:kore/services/signal_quality.dart';

EEGSample _sample(List<double> channels) =>
    EEGSample(timestamp: 0, channels: channels);

KorePacket _packet({
  int firstSampleIndex = 0,
  int sampleCount = 3,
  int channelCount = 1,
  List<ElectrodeContact> electrodes = const [],
  int? battery,
}) =>
    KorePacket(
      firstSampleIndex: firstSampleIndex,
      samples: [
        for (var s = 0; s < sampleCount; s++)
          _sample([for (var c = 0; c < channelCount; c++) 10.0 * (s + c + 1)]),
      ],
      electrodes: electrodes,
      batteryPercent: battery,
    );

/// Flip one byte, the way a corrupt payload arrives.
Uint8List _withByte(Uint8List bytes, int offset, int value) {
  final copy = Uint8List.fromList(bytes);
  copy[offset] = value;
  return copy;
}

void main() {
  group('round trip', () {
    test('samples survive encode and decode within quantisation', () {
      final original = _packet(firstSampleIndex: 4096, sampleCount: 8);
      final decoded = KorePacket.decode(original.encode(), 99);

      expect(decoded, isNotNull);
      expect(decoded!.firstSampleIndex, 4096);
      expect(decoded.length, 8);
      for (var i = 0; i < original.samples.length; i++) {
        // One LSB is 500/32767 = 0.0153 uV, and the sample values are
        // quantised twice on the way through.
        expect(decoded.samples[i].channels.single,
            closeTo(original.samples[i].channels.single, 0.02));
      }
      expect(decoded.samples.first.timestamp, 99,
          reason: 'stamped on arrival - the device does not send a clock');
    });

    test('multi-channel samples keep their channel order', () {
      final original = KorePacket(
        firstSampleIndex: 0,
        samples: [
          _sample([10.0, -20.0, 30.0]),
          _sample([-40.0, 50.0, -60.0]),
        ],
      );
      final decoded = KorePacket.decode(original.encode(), 0)!;

      expect(decoded.samples[0].channels.length, 3);
      expect(decoded.samples[0].channels[0], closeTo(10.0, 0.02));
      expect(decoded.samples[0].channels[1], closeTo(-20.0, 0.02));
      expect(decoded.samples[0].channels[2], closeTo(30.0, 0.02));
      expect(decoded.samples[1].channels[2], closeTo(-60.0, 0.02));
    });

    test('a full-scale sample does not wrap into its own negative', () {
      final decoded = KorePacket.decode(
          KorePacket(firstSampleIndex: 0, samples: [
            _sample([kFullScaleMicrovolts * 2]),
            _sample([-kFullScaleMicrovolts * 2]),
          ]).encode(),
          0)!;

      expect(decoded.samples[0].channels.single,
          closeTo(kFullScaleMicrovolts, 0.02));
      expect(decoded.samples[1].channels.single,
          closeTo(-kFullScaleMicrovolts, 0.02));
    });

    test('the index survives the top of its range', () {
      // 194 days of continuous streaming at 256 Hz. A session never reaches
      // it, but a decoder that sign-extended would turn it negative.
      const nearMax = 0xFFFFFFF0;
      final decoded = KorePacket.decode(
          _packet(firstSampleIndex: nearMax).encode(), 0)!;
      expect(decoded.firstSampleIndex, nearMax);
      expect(decoded.firstSampleIndex, greaterThan(0));
    });

    test('it is little-endian on the wire, as specified', () {
      final bytes = _packet(firstSampleIndex: 0x04030201).encode();
      expect(bytes.sublist(4, 8), [0x01, 0x02, 0x03, 0x04]);
    });
  });

  group('per-pad contact', () {
    test('measured pads round trip, and keep their positional names', () {
      final original = _packet(electrodes: const [
        ElectrodeContact(
            id: 'left', label: 'Left pad', contact: 0.9, impedanceKOhm: 12.0),
        ElectrodeContact(
            id: 'centre', label: 'Centre pad', contact: 0.1, impedanceKOhm: 180.0),
      ]);
      final decoded = KorePacket.decode(original.encode(), 0)!;

      expect(decoded.electrodes.length, 2);
      expect(decoded.electrodes[0].id, 'left');
      expect(decoded.electrodes[0].label, 'Left pad');
      expect(decoded.electrodes[0].contact, closeTo(0.9, 0.005));
      expect(decoded.electrodes[0].impedanceKOhm, 12.0);
      expect(decoded.electrodes[1].contact, closeTo(0.1, 0.005));
      expect(decoded.electrodes[1].impedanceKOhm, 180.0);
    });

    test('an unmeasurable pad stays null rather than becoming zero', () {
      // The distinction the whole nullable field exists for: a pad that cannot
      // be measured is not a pad measuring no contact, and rolling it up as
      // the worst electrode would put a working headset into "press it back
      // down" forever.
      final decoded = KorePacket.decode(
          _packet(electrodes: const [
            ElectrodeContact(id: 'left', label: 'Left pad', contact: null),
          ]).encode(),
          0)!;

      expect(decoded.electrodes.single.contact, isNull);
      expect(decoded.electrodes.single.impedanceKOhm, isNull);
    });

    test('no pad table is not a report of healthy pads', () {
      final decoded = KorePacket.decode(_packet().encode(), 0)!;
      expect(decoded.electrodes, isEmpty);

      final quality = SignalQuality.fromElectrodes(
        electrodes: decoded.electrodes,
        measuredRateHz: 256,
        referenceRateHz: 256,
      );
      expect(quality.contactMeasured, isFalse);
      expect(quality.hasPerElectrodeContact, isFalse);
    });

    test('a pad beyond the named set is still readable', () {
      // A five-pad patch must not be undecodable by an app that knows four.
      final decoded = KorePacket.decode(
          _packet(electrodes: [
            for (var i = 0; i < 5; i++)
              ElectrodeContact(
                  id: 'x', label: 'x', contact: 0.5, impedanceKOhm: 20),
          ]).encode(),
          0)!;

      expect(decoded.electrodes.length, 5);
      expect(decoded.electrodes[4].id, 'pad5');
      expect(decoded.electrodes[4].label, 'Pad 5');
    });

    test('the decoded pads feed the quality rollup unchanged', () {
      final decoded = KorePacket.decode(
          _packet(electrodes: const [
            ElectrodeContact(id: 'left', label: 'Left pad', contact: 0.95),
            ElectrodeContact(id: 'centre', label: 'Centre pad', contact: 0.05),
          ]).encode(),
          0)!;

      final quality = SignalQuality.fromElectrodes(
        electrodes: decoded.electrodes,
        measuredRateHz: 256,
        referenceRateHz: 256,
      );
      // Worst pad wins, and the user is told which one.
      expect(quality.level, SignalQualityLevel.unusable);
      expect(quality.electrodesNeedingAttention.first.label, 'Centre pad');
    });
  });

  group('battery', () {
    test('a reported battery round trips', () {
      expect(KorePacket.decode(_packet(battery: 42).encode(), 0)!.batteryPercent,
          42);
    });

    test('a byte that cannot be a percentage is not shown as one', () {
      // The other input path in this repo already refuses the whole range;
      // shipping two answers for one field is how a pairing screen ends up
      // reading "KORE patch - 254%".
      final bytes = _packet(battery: 50).encode();
      for (final raw in [101, 150, 254, 255]) {
        expect(KorePacket.decode(_withByte(bytes, 9, raw), 0)!.batteryPercent,
            isNull,
            reason: 'battery byte $raw');
      }
      expect(KorePacket.decode(_withByte(bytes, 9, 100), 0)!.batteryPercent, 100);
      expect(KorePacket.decode(_withByte(bytes, 9, 0), 0)!.batteryPercent, 0);
    });

    test('an unreported battery is null, not zero', () {
      // A fabricated reading is a worse answer than an absent one, and a zero
      // here would render as a flat patch on the pairing screen.
      expect(KorePacket.decode(_packet().encode(), 0)!.batteryPercent, isNull);
    });
  });

  group('gap counting', () {
    test('a contiguous stream reports nothing missing', () {
      final first = _packet(firstSampleIndex: 1000, sampleCount: 64);
      expect(first.nextSampleIndex, 1064);
      expect(KorePacket.samplesMissingSince(1064, 1064), 0);
    });

    test('a lost notification is counted exactly, not inferred', () {
      // The entire reason firstSampleIndex is on the wire. One 64-sample
      // notification goes missing; the next packet says so by arithmetic
      // rather than by anybody timing its arrival.
      expect(KorePacket.samplesMissingSince(1064, 1128), 64);
    });

    test('a device that restarts its counter is a new stream, not a gap', () {
      // Backwards means a reconnect or a reset. Reading it as a gap would
      // report four billion missing samples and put the session into a
      // permanent fault.
      expect(KorePacket.samplesMissingSince(500000, 0), 0);
      expect(KorePacket.samplesMissingSince(500000, 499999), 0);
    });
  });

  group('a packet that cannot be trusted is refused whole', () {
    test('a truncated payload decodes to nothing', () {
      final bytes = _packet(sampleCount: 8).encode();
      for (final cut in [0, 1, KorePacket.headerBytes - 1, bytes.length - 1]) {
        expect(KorePacket.decode(Uint8List.sublistView(bytes, 0, cut), 0), isNull,
            reason: 'truncated to $cut bytes');
      }
    });

    test('a payload longer than its header describes is refused', () {
      // Sender and decoder disagree about the layout, so the samples are as
      // likely to be misaligned as trailing. Decoding the prefix would hand
      // the DSP a block that looks complete.
      final bytes = _packet().encode();
      final padded = Uint8List(bytes.length + 2)..setAll(0, bytes);
      expect(KorePacket.decode(padded, 0), isNull);
    });

    test('an unknown format version is refused rather than guessed at', () {
      final bytes = _packet().encode();
      expect(KorePacket.decode(_withByte(bytes, 0, 0), 0), isNull);
      expect(
          KorePacket.decode(
              _withByte(bytes, 0, KorePacket.formatVersion + 1), 0),
          isNull);
    });

    test('zero channels or zero samples is malformed, not empty', () {
      final bytes = _packet().encode();
      expect(KorePacket.decode(_withByte(bytes, 1, 0), 0), isNull,
          reason: 'no channels cannot carry a reading');
      final noSamples = Uint8List.fromList(bytes)
        ..[2] = 0
        ..[3] = 0;
      expect(KorePacket.decode(noSamples, 0), isNull);
    });

    test('a claimed sample count the payload cannot hold is refused', () {
      final bytes = _packet(sampleCount: 3).encode();
      expect(KorePacket.decode(_withByte(bytes, 2, 200), 0), isNull);
    });

    test('a claimed pad count the payload cannot hold is refused', () {
      final bytes = _packet(sampleCount: 3).encode();
      expect(KorePacket.decode(_withByte(bytes, 8, 40), 0), isNull);
    });

    test('a decode never throws, whatever arrives', () {
      // A radio delivers whatever it delivers. Every length and a scan of
      // header bytes, asserting only that nothing escapes.
      for (var len = 0; len < 40; len++) {
        final bytes = Uint8List(len);
        expect(() => KorePacket.decode(bytes, 0), returnsNormally);
        for (var b = 0; b < 256; b += 17) {
          expect(() => KorePacket.decode(Uint8List(len)..fillRange(0, len, b), 0),
              returnsNormally);
        }
      }
    });
  });

  test('decoding reads from a view, not from offset zero of its buffer', () {
    // A BLE stack hands up a view into a larger receive buffer. A decoder
    // using ByteData.view(bytes.buffer) alone reads the wrong bytes and is
    // very hard to see - the same trap the old fromBLEBytes documented.
    final packet = _packet(firstSampleIndex: 777, sampleCount: 4);
    final encoded = packet.encode();

    final backing = Uint8List(encoded.length + 8);
    backing.setAll(8, encoded);
    final view = Uint8List.sublistView(backing, 8);

    final decoded = KorePacket.decode(view, 0);
    expect(decoded, isNotNull);
    expect(decoded!.firstSampleIndex, 777);
    expect(decoded.length, 4);
  });
}
