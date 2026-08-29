import 'dart:async';
import 'dart:typed_data';

import '../services/ble_packet.dart';
import '../services/eeg_data_stream.dart';
import '../services/kore_ble.dart';
import '../services/signal_quality.dart';
import 'demo_controls.dart';
import 'eeg_source.dart';
import 'source_link.dart';

/// The radio, behind the seam.
///
/// Everything that decides anything lives here in Dart, and the host below it
/// scans, connects, subscribes and forwards bytes. That split is deliberate
/// and it is what makes step 4 testable at all: the link state machine, the
/// gap counting, the rate measurement and the quality reporting are the parts
/// that can be got wrong in ways nobody notices, and every one of them is
/// exercised on the host VM against a fake channel. What is left on the
/// Kotlin side is the part a device either does or does not do.
///
/// It is a drop-in by construction - `KoreSession` holds an [EegSource] and
/// nothing downstream of it knows this class exists - and [demo] returns null,
/// so the demo panel disappears on a real patch rather than shipping a
/// "Simulate detached electrode" button to somebody wearing one.
class BleEegSource implements EegSource {
  /// Notifications to average before claiming to know the sample rate.
  ///
  /// A rate is a count over an interval, and both ends of the interval are
  /// arrival timestamps taken on a phone that was free to be busy. One packet
  /// gives nothing; a few seconds of them average the jitter down to where the
  /// answer is worth building a 60 Hz notch against. At 4 packets a second
  /// this is about four seconds - which is exactly the window
  /// `KoreSession._retuneToMeasuredRate` exists to cover, and why
  /// [rateMeasured] is on the seam at all.
  static const int kPacketsToMeasureRate = 16;

  /// Below this the measurement is not believed and the nominal stands.
  ///
  /// A phone that was descheduled for a second mid-window produces an interval
  /// that says the crystal is 30% slow. `DspConfig.forMeasuredRate` would
  /// refuse it anyway, but refusing it here means [rateMeasured] stays false
  /// and the session keeps waiting for a real answer rather than being told
  /// one has arrived.
  static const double kMaxPlausibleRateError = 0.10;

  final KoreBle _ble;

  /// The rate the patch is built to, before anything is measured.
  @override
  final int samplingRateHz;

  final _blocks = StreamController<SampleBlock>.broadcast();
  final _qualityUpdates = StreamController<SignalQuality>.broadcast();
  final _linkUpdates = StreamController<SourceLink>.broadcast();

  StreamSubscription<Uint8List>? _packets;
  StreamSubscription<BleLinkEvent>? _events;

  SourceLink _link = SourceLink.idle;
  SignalQuality _quality = SignalQuality.unreported;

  /// Where the device's stream is expected to resume, or null before the first
  /// packet of a connection.
  int? _expectedSampleIndex;

  /// Arrival time and cumulative sample count at the start of the measurement
  /// window.
  int? _rateWindowStartMicros;
  int _rateWindowSamples = 0;
  int _rateWindowPackets = 0;

  double? _measuredRateHz;

  /// Injectable for tests, for the same reason the simulator's clock is: a
  /// rate measured from arrival times cannot be tested against a clock that
  /// only moves when the test is not looking.
  final int Function() _nowMicros;

  BleEegSource({
    KoreBle? ble,
    this.samplingRateHz = 256,
    int Function()? nowMicros,
  })  : _ble = ble ?? createKoreBle(),
        _nowMicros = nowMicros ?? _defaultNowMicros;

  static int _defaultNowMicros() =>
      DateTime.now().microsecondsSinceEpoch;

  @override
  Stream<SampleBlock> get sampleBlocks => _blocks.stream;

  @override
  Stream<SignalQuality> get qualityUpdates => _qualityUpdates.stream;

  @override
  Stream<SourceLink> get linkUpdates => _linkUpdates.stream;

  @override
  SignalQuality get quality => _quality;

  @override
  SourceLink get link => _link;

  @override
  String get label => 'KORE patch';

  /// Null, and that is the point. A real patch offers no levers, so the demo
  /// panel is off by construction rather than behind a flag somebody has to
  /// remember to set before a session with a person wearing hardware.
  @override
  DemoControls? get demo => null;

  @override
  bool get rateMeasured => _measuredRateHz != null;

  @override
  double get effectiveSampleRateHz =>
      _measuredRateHz ?? samplingRateHz.toDouble();

  /// Whether this build reached a host at all. False means [start] will fail,
  /// and `createEegSource` will have chosen the simulator instead.
  bool get isSupported => _ble.isSupported;

  @override
  Future<void> start() async {
    if (_events != null) return;

    _events = _ble.events.listen(_onEvent);
    _packets = _ble.packets.listen(_onPacket);

    _publishLink(const SourceLink(state: SourceLinkState.scanning));
    try {
      await _ble.startScan();
    } catch (e) {
      _publishLink(SourceLink(
        state: SourceLinkState.failed,
        failure: 'Could not start scanning ($e)',
      ));
    }
  }

  @override
  Future<void> stop() async {
    final packets = _packets;
    final events = _events;
    _packets = null;
    _events = null;
    _resetStreamState();

    // Published before the await, not after it. `stop()` nulls the
    // subscriptions first, so a `start()` arriving during the disconnect sees
    // an idle source and legitimately re-subscribes and re-scans - and a
    // `finally` running afterwards would then stamp `idle` over a link that
    // had just come back, leaving the screen idle while packets flowed.
    _publishLink(SourceLink.idle);

    await packets?.cancel();
    await events?.cancel();
    await _ble.disconnect();
  }

  @override
  void dispose() {
    _packets?.cancel();
    _events?.cancel();
    _ble.dispose();
    _blocks.close();
    _qualityUpdates.close();
    _linkUpdates.close();
  }

  /// Everything that describes *this* connection's stream, and nothing that
  /// describes the patch.
  ///
  /// Called on every disconnection. The sample index restarts with the device,
  /// and the rate measurement has to restart with it too - a window straddling
  /// a reconnection spans a stretch when no packets arrived at all, and would
  /// report a crystal running at a fraction of its true rate. That number
  /// would then be believed, and a notch built against it.
  void _resetStreamState() {
    _expectedSampleIndex = null;
    _rateWindowStartMicros = null;
    _rateWindowSamples = 0;
    _rateWindowPackets = 0;
    _measuredRateHz = null;
  }

  void _onEvent(BleLinkEvent event) {
    switch (event.state) {
      case BleLinkState.scanning:
        _publishLink(const SourceLink(state: SourceLinkState.scanning));
      case BleLinkState.connecting:
        _publishLink(SourceLink(
          state: SourceLinkState.connecting,
          patch: _identityFrom(event),
        ));
      case BleLinkState.streaming:
        _publishLink(SourceLink(
          state: SourceLinkState.streaming,
          patch: _identityFrom(event),
        ));
      case BleLinkState.reconnecting:
        // The stream is broken here, not when it comes back. Clearing now
        // means the first packet after the gap is treated as the start of a
        // new stream rather than differenced against an index the device has
        // long since abandoned.
        _resetStreamState();
        _publishLink(SourceLink(
          state: SourceLinkState.reconnecting,
          patch: _identityFrom(event),
        ));
      case BleLinkState.failed:
        _resetStreamState();
        _publishLink(SourceLink(
          state: SourceLinkState.failed,
          patch: _identityFrom(event),
          failure: event.failure,
        ));
      case BleLinkState.idle:
        _resetStreamState();
        _publishLink(SourceLink.idle);
    }
  }

  PatchIdentity? _identityFrom(BleLinkEvent event) {
    final name = event.deviceName;
    if (name == null) return _link.patch;
    return PatchIdentity(name: name, batteryPercent: event.batteryPercent);
  }

  void _onPacket(Uint8List bytes) {
    final arrivedAt = _nowMicros();
    final packet = KorePacket.decode(bytes, arrivedAt ~/ 1000);
    if (packet == null) {
      // Dropped whole, and deliberately not reported as a dropout. Nothing is
      // known about how many samples it held - that count is inside the packet
      // that could not be read - and the *next* packet reports the gap exactly,
      // through its own first sample index. Guessing here would double-count
      // it.
      return;
    }

    final dropped = _expectedSampleIndex == null
        ? 0
        : KorePacket.samplesMissingSince(
            _expectedSampleIndex!, packet.firstSampleIndex);
    _expectedSampleIndex = packet.nextSampleIndex;

    // The samples the *device produced* over this interval, not the ones that
    // survived the air. See [_accumulateRate].
    _accumulateRate(arrivedAt, packet.length + dropped);

    final quality = SignalQuality.fromElectrodes(
      electrodes: packet.electrodes,
      droppedSamples: dropped,
      measuredRateHz: effectiveSampleRateHz,
      // What the analysis is tuned to is not knowable here; the session's
      // `SignalQualityGate` re-references this to the engine's actual tuning.
      // Reporting the nominal is the most this side can honestly say.
      referenceRateHz: samplingRateHz.toDouble(),
    );

    _publishQuality(quality);

    if (packet.batteryPercent != null) _updateBattery(packet.batteryPercent!);

    if (!_blocks.isClosed) {
      _blocks.add(SampleBlock(
        samples: packet.samples,
        firstSampleIndex: packet.firstSampleIndex,
        quality: quality,
      ));
    }
  }

  /// Fold one packet into the rate measurement.
  ///
  /// Samples per second of wall clock, over a window of whole packets. Counting
  /// *samples* rather than packets is what makes it a sample-rate measurement:
  /// a device that coalesces two notifications into one still delivered the
  /// same number of samples in the same interval.
  ///
  /// [samples] is what the device *produced*, so it includes samples that were
  /// lost on the way here. This is the whole correctness of the measurement and
  /// it is easy to get backwards. The interval is wall clock, and the crystal
  /// kept ticking through a dropped notification; counting only what arrived
  /// divides the survivors by the time it took to send all of them, and the
  /// answer is low by exactly the loss fraction. One notification lost in four
  /// seconds reads as a 6% slow crystal - comfortably inside the plausibility
  /// band, so it is believed rather than refused, and
  /// `KoreSession._retuneToMeasuredRate` spends its one rebuild tuning a
  /// 60 Hz notch to 63.75 Hz. Nothing downstream can catch it either: the gate
  /// re-references drift to whatever the engine was tuned to, so the error
  /// reads as zero drift.
  ///
  /// The correction costs nothing, because the count of missing samples is
  /// exactly what `firstSampleIndex` is on the wire for.
  void _accumulateRate(int arrivedAtMicros, int samples) {
    if (_rateWindowStartMicros == null) {
      // The first packet starts the clock and contributes no samples to it:
      // the interval this measures begins when that packet arrived, so its own
      // samples were delivered before the window opened.
      _rateWindowStartMicros = arrivedAtMicros;
      _rateWindowSamples = 0;
      _rateWindowPackets = 0;
      return;
    }

    _rateWindowSamples += samples;
    _rateWindowPackets++;
    if (_rateWindowPackets < kPacketsToMeasureRate) return;

    final elapsed = (arrivedAtMicros - _rateWindowStartMicros!) / 1e6;
    // Restart rather than divide: a non-positive interval means the clock went
    // backwards or two packets shared a timestamp, and neither is a rate.
    if (elapsed <= 0) {
      _rateWindowStartMicros = arrivedAtMicros;
      _rateWindowSamples = 0;
      _rateWindowPackets = 0;
      return;
    }

    final hz = _rateWindowSamples / elapsed;
    final error = (hz - samplingRateHz).abs() / samplingRateHz;
    if (error <= kMaxPlausibleRateError) {
      _measuredRateHz = hz;
    }
    // Either way the window closes and a fresh one opens. A measurement that
    // was refused as implausible must not be retried against a stale start
    // time that already contains whatever stalled the phone.
    _rateWindowStartMicros = arrivedAtMicros;
    _rateWindowSamples = 0;
    _rateWindowPackets = 0;
  }

  void _updateBattery(int percent) {
    final patch = _link.patch;
    if (patch == null || patch.batteryPercent == percent) return;
    _publishLink(SourceLink(
      state: _link.state,
      patch: PatchIdentity(name: patch.name, batteryPercent: percent),
      failure: _link.failure,
    ));
  }

  void _publishQuality(SignalQuality next) {
    // Emitted on change of verdict, matching the simulator: the block already
    // carries the report, and a stream event per notification would be four a
    // second saying the same thing.
    final changed = next.level != _quality.level ||
        !_sameFaults(next.faults, _quality.faults) ||
        !_samePadStates(next, _quality);
    _quality = next;
    if (changed && !_qualityUpdates.isClosed) _qualityUpdates.add(next);
  }

  static bool _sameFaults(Set<SignalFault> a, Set<SignalFault> b) =>
      a.length == b.length && a.containsAll(b);

  /// Whether every pad still reads in the same band as it did.
  ///
  /// The same comparison the simulator makes, and needed here for a reason
  /// that shows up first on a real patch: the very first packet takes the
  /// report from "no pads measured" to "four pads, all good", which moves
  /// neither the aggregate level nor the fault set. Without this the pairing
  /// screen would never hear that contact had been measured at all, and the
  /// Continue button it gates on `allPadsSeated` would stay dark in front of
  /// somebody wearing a perfectly seated headset.
  static bool _samePadStates(SignalQuality a, SignalQuality b) {
    if (a.electrodes.length != b.electrodes.length) return false;
    for (var i = 0; i < a.electrodes.length; i++) {
      if (a.electrodes[i].id != b.electrodes[i].id) return false;
      if (a.electrodes[i].state != b.electrodes[i].state) return false;
    }
    return true;
  }

  void _publishLink(SourceLink next) {
    final changed = next.state != _link.state ||
        next.patch?.name != _link.patch?.name ||
        next.patch?.batteryPercent != _link.patch?.batteryPercent ||
        next.failure != _link.failure;
    _link = next;
    if (changed && !_linkUpdates.isClosed) _linkUpdates.add(next);
  }
}
