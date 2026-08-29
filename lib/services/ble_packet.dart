import 'dart:typed_data';

import 'eeg_data_stream.dart';
import 'signal_quality.dart';

/// One BLE notification from the patch, decoded.
///
/// This is the contract the firmware has to meet, written down before there is
/// firmware - the same reason [EEGSample.fromBLEBytes] exists. What is new is
/// *what* has to be in it, because the old per-sample format predates the
/// widened `EegSource` and can no longer carry what the seam asks for.
///
/// `docs/hardware-seam.md` named three things a real link has to express, and
/// two of them are properties of a *packet*, not of a sample:
///
/// - **Where the samples sat in the device's own stream.** `SampleBlock`
///   carries `firstSampleIndex` so a gap is *counted* rather than inferred
///   from arrival times, and there was nowhere on the wire to put it. Without
///   it a dropped notification is spliced out silently, and the Hann-windowed
///   Goertzel turns the discontinuity into broadband power landing in theta
///   and alpha at once - which the index reads as cognitive load.
/// - **Per-electrode contact.** `SignalQuality.fromElectrodes` rolls up the
///   worst pad and tells the user *which one* to press down. That has to come
///   from the device; nothing in the DSP can recover it, because a detached
///   electrode produces a genuinely elevated theta/alpha ratio rather than
///   silence.
///
/// Both are per-notification, so both belong here rather than repeated on
/// every sample.
///
/// ## Wire format
///
/// Little-endian throughout, which is what every ARM Cortex-M part a patch
/// would use is natively.
///
/// ```text
///   offset  size  field
///   0       1     version          u8   - see [formatVersion]
///   1       1     channelCount     u8
///   2       2     sampleCount      u16
///   4       4     firstSampleIndex u32  - device-side, monotonic
///   8       1     padCount         u8
///   9       1     battery          u8   - 0-100, or 0xFF for "not measured"
///   10      2     reserved         u16  - must be zero
///   12      ...   pads             padCount x { contact u8, impedance u16 }
///           ...   samples          sampleCount x channelCount x i16
/// ```
///
/// A pad's `contact` is 0-200 scaled from 0.0-1.0, or `0xFF` meaning this pad
/// cannot be measured - which is not the same as measuring zero, and the
/// nullability of [ElectrodeContact.contact] exists to keep those apart.
/// `impedance` is kilohms, `0xFFFF` for absent.
///
/// ## Why the index is 32 bits and wraps
///
/// At 256 Hz a `u32` runs for 194 days of continuous streaming, so a session
/// will never see it wrap. Firmware that resets its counter on reconnect will,
/// though, and the decoder does not care: the index is only ever *differenced*
/// against the previous packet, and [KorePacket.samplesMissingSince] treats a
/// backwards jump as a stream restart rather than as a gap of four billion.
class KorePacket {
  /// Bumped when the layout changes in a way an old app cannot read.
  ///
  /// Checked rather than assumed. A patch on stale firmware is a normal thing
  /// to meet in the field, and it must be refused as *unreadable* rather than
  /// decoded into plausible nonsense - the failure mode of a mis-parsed EEG
  /// packet is not a crash, it is a number on a dial that means nothing.
  static const int formatVersion = 1;

  /// Bytes before the pad table.
  static const int headerBytes = 12;

  static const int _padBytes = 3;
  static const int _batteryAbsent = 0xFF;
  static const int _contactAbsent = 0xFF;
  static const int _impedanceAbsent = 0xFFFF;

  /// Full scale of the contact byte. 200 rather than 255 so the value is a
  /// round 0.5% per step and `0xFF` stays clearly outside the range rather
  /// than being one step past the top of it.
  static const int contactFullScale = 200;

  static const int _int16Max = 32767;

  /// Device-side index of the first sample in this packet.
  final int firstSampleIndex;

  /// The samples, already in microvolts.
  final List<EEGSample> samples;

  /// Per-pad contact as the device measured it. Empty when the patch has no
  /// impedance front end, which is not the same as reporting healthy pads.
  final List<ElectrodeContact> electrodes;

  /// 0-100, or null when the patch does not report it.
  final int? batteryPercent;

  const KorePacket({
    required this.firstSampleIndex,
    required this.samples,
    this.electrodes = const [],
    this.batteryPercent,
  });

  int get length => samples.length;

  /// One past the last sample in this packet, i.e. the index the next packet
  /// should start at if nothing was lost.
  int get nextSampleIndex => firstSampleIndex + samples.length;

  /// How many samples went missing between [previousNextIndex] and this
  /// packet, or zero.
  ///
  /// Zero for the first packet of a stream, and zero for a backwards jump.
  /// Backwards means the device restarted its counter - a reconnect, a reset -
  /// and the honest reading of that is "a new stream", not "minus four billion
  /// samples". The *discontinuity* still has to be refused, but that is the
  /// link's business and it reports it by returning to `connecting`, which
  /// already contaminates the analysis window.
  static int samplesMissingSince(int previousNextIndex, int firstSampleIndex) {
    final gap = firstSampleIndex - previousNextIndex;
    return gap > 0 ? gap : 0;
  }

  /// Decode a notification, or return null if it cannot be trusted.
  ///
  /// Null rather than a throw, and null rather than a best effort. A radio
  /// delivers truncated and corrupt payloads as a matter of course; the caller
  /// drops the packet and the *next* one reports the gap through
  /// [firstSampleIndex], which is precisely the mechanism that makes a lost
  /// notification countable. Decoding half a packet would hand the DSP a
  /// short block that looks complete, and nothing downstream could tell.
  static KorePacket? decode(Uint8List bytes, int timestamp) {
    if (bytes.lengthInBytes < headerBytes) return null;

    final data =
        ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);

    if (data.getUint8(0) != formatVersion) return null;

    final channelCount = data.getUint8(1);
    final sampleCount = data.getUint16(2, Endian.little);
    final firstSampleIndex = data.getUint32(4, Endian.little);
    final padCount = data.getUint8(8);
    final batteryRaw = data.getUint8(9);

    // A packet with no channels cannot carry a reading, and one with no
    // samples is not a delivery. Both are malformed rather than empty.
    if (channelCount == 0 || sampleCount == 0) return null;

    final padTableBytes = padCount * _padBytes;
    final sampleBytes = sampleCount * channelCount * 2;
    // Exactly, not at least. A payload longer than its header describes means
    // the sender and this decoder disagree about the layout, and the samples
    // are as likely to be misaligned as trailing.
    if (bytes.lengthInBytes != headerBytes + padTableBytes + sampleBytes) {
      return null;
    }

    var offset = headerBytes;
    final electrodes = <ElectrodeContact>[];
    for (var i = 0; i < padCount; i++) {
      final contactRaw = data.getUint8(offset);
      final impedanceRaw = data.getUint16(offset + 1, Endian.little);
      offset += _padBytes;

      electrodes.add(ElectrodeContact(
        id: padIdAt(i),
        label: padLabelAt(i),
        contact: contactRaw == _contactAbsent
            ? null
            // Clamped rather than refused: a firmware that reports 210 is
            // saying "as good as it gets" in a unit it got slightly wrong, and
            // throwing the whole packet away over it would cost a reading to
            // make a point.
            : (contactRaw / contactFullScale).clamp(0.0, 1.0),
        impedanceKOhm:
            impedanceRaw == _impedanceAbsent ? null : impedanceRaw.toDouble(),
      ));
    }

    final samples = <EEGSample>[];
    for (var s = 0; s < sampleCount; s++) {
      final channels = <double>[];
      for (var c = 0; c < channelCount; c++) {
        final raw = data.getInt16(offset, Endian.little);
        offset += 2;
        channels.add((raw / _int16Max) * kFullScaleMicrovolts);
      }
      samples.add(EEGSample(timestamp: timestamp, channels: channels));
    }

    return KorePacket(
      firstSampleIndex: firstSampleIndex,
      samples: samples,
      electrodes: electrodes,
      batteryPercent: batteryRaw == _batteryAbsent ? null : batteryRaw,
    );
  }

  /// Encode, for the firmware-side reference and for round-trip tests.
  ///
  /// The app never sends one of these. It exists so the format has exactly one
  /// definition rather than a decoder here and a prose description in a
  /// firmware repo that drifts from it.
  Uint8List encode() {
    final channelCount = samples.isEmpty ? 0 : samples.first.channels.length;
    final data = ByteData(headerBytes +
        electrodes.length * _padBytes +
        samples.length * channelCount * 2);

    data.setUint8(0, formatVersion);
    data.setUint8(1, channelCount);
    data.setUint16(2, samples.length, Endian.little);
    data.setUint32(4, firstSampleIndex, Endian.little);
    data.setUint8(8, electrodes.length);
    data.setUint8(9, batteryPercent ?? _batteryAbsent);
    data.setUint16(10, 0, Endian.little);

    var offset = headerBytes;
    for (final e in electrodes) {
      final contact = e.contact;
      data.setUint8(
          offset,
          contact == null
              ? _contactAbsent
              : (contact.clamp(0.0, 1.0) * contactFullScale).round());
      final impedance = e.impedanceKOhm;
      data.setUint16(
          offset + 1,
          impedance == null
              ? _impedanceAbsent
              : impedance.round().clamp(0, _impedanceAbsent - 1),
          Endian.little);
      offset += _padBytes;
    }

    for (final sample in samples) {
      for (var c = 0; c < channelCount; c++) {
        final uv = c < sample.channels.length ? sample.channels[c] : 0.0;
        final raw = ((uv / kFullScaleMicrovolts) * _int16Max)
            .round()
            .clamp(-_int16Max, _int16Max);
        data.setInt16(offset, raw, Endian.little);
        offset += 2;
      }
    }

    return data.buffer.asUint8List(0, offset);
  }

  /// Stable machine keys for pads, by wire position.
  ///
  /// The wire carries an ordinal, not a name: a name per pad on every
  /// notification is bytes spent, at 4 Hz, on a string that never changes.
  /// Positions beyond the known set get a generated id rather than being
  /// dropped, so a five-pad patch is readable by an app that knows four.
  static String padIdAt(int i) =>
      i < _padIds.length ? _padIds[i] : 'pad${i + 1}';

  /// User-facing pad names, positional and lay - never a 10-20 designator, per
  /// [ElectrodeContact.label].
  static String padLabelAt(int i) =>
      i < _padLabels.length ? _padLabels[i] : 'Pad ${i + 1}';

  static const List<String> _padIds = ['left', 'centre', 'right', 'reference'];
  static const List<String> _padLabels = [
    'Left pad',
    'Centre pad',
    'Right pad',
    'Reference pad',
  ];
}
