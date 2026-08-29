import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The radio's half of the platform channel.
///
/// The second instance of the shape `kore_platform.dart` established, and the
/// one it was established *for*: `docs/hardware-seam.md` took the notification
/// tier first deliberately, because getting this wrong where a failure costs
/// one missing banner is cheaper than discovering it with an EEG link
/// attached. Everything here is copied from that file on purpose - one
/// `MethodChannel` in the repo, nothing in `pubspec.yaml`, no symlink
/// requirement, nothing a host-VM test has to bind, and an inert
/// implementation everywhere there is no host so the desktop build carries no
/// conditionals.
///
/// The division of labour is the part worth stating. This channel is a pipe:
/// scan, connect, subscribe, hand up bytes, say what the link is doing. It
/// decides nothing. Gap counting, rate measurement, quality reporting and the
/// link state machine all live in [BleEegSource] in Dart, where they can be
/// tested on the host VM against a fake channel - which is most of why step 4
/// is testable before there is a patch to test it against.

/// What the host says the radio is doing.
///
/// Deliberately not `SourceLinkState`: that enum is what the *app* shows, and
/// it is the source's job to translate. A host that grew a sixth state would
/// otherwise be changing a type the pairing screen switches over.
enum BleLinkState { idle, scanning, connecting, streaming, reconnecting, failed }

/// One link transition from the host.
@immutable
class BleLinkEvent {
  final BleLinkState state;

  /// The advertised name, once there is a device. Null means "unchanged" -
  /// a reconnecting event does not re-send the identity of the patch it is
  /// reconnecting to.
  final String? deviceName;

  /// 0-100 from the battery characteristic, or null when the patch has none
  /// or has not been read yet.
  final int? batteryPercent;

  /// Why, on [BleLinkState.failed]. Shown to the user, so it has to be a
  /// sentence rather than a status code.
  final String? failure;

  const BleLinkEvent({
    required this.state,
    this.deviceName,
    this.batteryPercent,
    this.failure,
  });

  /// Decodes what the host sent, refusing anything it does not recognise.
  ///
  /// An unknown state name becomes null rather than a guess: a link state the
  /// app does not understand must not be rendered as `streaming`, which is the
  /// only state in which a reading on screen means anything.
  static BleLinkEvent? fromMap(Object? message) {
    if (message is! Map) return null;
    final name = message['state'];
    if (name is! String) return null;

    for (final state in BleLinkState.values) {
      if (state.name != name) continue;
      final battery = message['battery'];
      return BleLinkEvent(
        state: state,
        deviceName: message['name'] is String ? message['name'] as String : null,
        batteryPercent:
            battery is int && battery >= 0 && battery <= 100 ? battery : null,
        failure:
            message['failure'] is String ? message['failure'] as String : null,
      );
    }
    return null;
  }
}

/// The host side of the radio, as the app sees it.
abstract class KoreBle {
  /// Raw notification payloads, in arrival order. Decoded by [KorePacket] on
  /// the Dart side - the host does not parse the format, so firmware and
  /// decoder cannot drift apart across a language boundary.
  Stream<Uint8List> get packets;

  /// Link transitions.
  Stream<BleLinkEvent> get events;

  /// Begin scanning. Completing means scanning started, not that a device was
  /// found - finding one arrives on [events].
  Future<void> startScan();

  /// Drop the link and stop scanning. Safe when neither is happening.
  Future<void> disconnect();

  /// Whether this build reached a host. False means every call above is inert.
  bool get isSupported;

  void dispose();
}

/// Whether an Android host for `kore/ble` is installed in this build.
///
/// **False, because there is not one yet.** `MainActivity.kt` registers
/// `kore/platform` and nothing else; the Kotlin half of the radio is the piece
/// step 4 still owes.
///
/// This is a constant rather than a probe because the choice has to be made
/// synchronously, in [createKoreBle], before a `KoreSession` exists - and a
/// channel cannot be asked whether anyone is listening without awaiting a
/// round trip. Every asynchronous answer arrives after the decision.
///
/// It is here, named, rather than left implicit in a commented-out branch,
/// because the alternative was worse: [AndroidKoreBle.isSupported] returning a
/// hardcoded `true` claimed a host that does not exist, `createEegSource()`
/// believed it, and every Android build got a [BleEegSource] wired to nothing.
/// The app would have shown a pairing screen that scanned forever - not a
/// crash, not a log line, just a device that never appears. Flip this the day
/// the Kotlin lands, in the same commit.
const bool kAndroidBleHostInstalled = false;

/// Returns the radio channel if this build has a host for it, and an inert one
/// otherwise.
///
/// Android only, exactly as `createKorePlatform()` is. Windows gets the inert
/// one, which is why `createEegSource()` can choose the simulator there
/// without a single platform conditional of its own.
KoreBle createKoreBle() {
  if (kIsWeb) return const InertKoreBle();
  if (!kAndroidBleHostInstalled) return const InertKoreBle();
  try {
    if (Platform.isAndroid) return AndroidKoreBle();
  } catch (e) {
    debugPrint('KORE: BLE channel unavailable ($e); no radio');
  }
  return const InertKoreBle();
}

/// No radio. Every call succeeds and nothing ever arrives.
///
/// [startScan] completing rather than throwing is the same call
/// `_InertPlatform` makes: a caller that had to guard each call would grow the
/// platform conditional in five places. The absence is reported once, through
/// [isSupported], and `createEegSource()` is the one place that reads it.
@visibleForTesting
class InertKoreBle implements KoreBle {
  const InertKoreBle();

  @override
  Stream<Uint8List> get packets => const Stream.empty();

  @override
  Stream<BleLinkEvent> get events => const Stream.empty();

  @override
  Future<void> startScan() async {}

  @override
  Future<void> disconnect() async {}

  @override
  bool get isSupported => false;

  @override
  void dispose() {}
}

/// The Android host: one [MethodChannel] out, one [EventChannel] in.
///
/// Two channels rather than one, which is the one place this departs from
/// `kore_platform.dart`. Notifications arrive at up to the packet rate and
/// carry binary payloads; an [EventChannel] is a stream in exactly that
/// direction and does not make every notification a round trip with a reply
/// nobody reads.
///
/// Visible for testing: the suite drives both channels through
/// `TestDefaultBinaryMessengerBinding`, so the call sequence, the decoding and
/// the failure paths are checked on the host VM with no device attached.
@visibleForTesting
class AndroidKoreBle implements KoreBle {
  static const MethodChannel commands = MethodChannel('kore/ble');
  static const EventChannel stream = EventChannel('kore/ble/stream');

  final _packets = StreamController<Uint8List>.broadcast();
  final _events = StreamController<BleLinkEvent>.broadcast();

  StreamSubscription<dynamic>? _hostStream;

  AndroidKoreBle() {
    _hostStream = stream.receiveBroadcastStream().listen(
          _onHostMessage,
          onError: _onHostError,
        );
  }

  @override
  Stream<Uint8List> get packets => _packets.stream;

  @override
  Stream<BleLinkEvent> get events => _events.stream;

  @override
  bool get isSupported => true;

  /// One stream carrying both payloads and transitions, told apart by type.
  ///
  /// A payload is bytes and a transition is a map, which the platform codec
  /// preserves. Sharing the stream keeps them *ordered* with respect to each
  /// other, and that ordering is load-bearing: a `reconnecting` that overtook
  /// the last packets before the drop would clear the sample index while
  /// packets from the old stream were still in flight, and the first packet
  /// after it would be differenced against nothing.
  void _onHostMessage(dynamic message) {
    if (message is Uint8List) {
      if (!_packets.isClosed) _packets.add(message);
      return;
    }
    final event = BleLinkEvent.fromMap(message);
    if (event != null && !_events.isClosed) _events.add(event);
  }

  void _onHostError(Object error) {
    // The host's stream failing is a link failure, not an app failure. It
    // arrives as one so the pairing screen can say something rather than
    // waiting forever for a device.
    if (_events.isClosed) return;
    _events.add(BleLinkEvent(
      state: BleLinkState.failed,
      failure: error is PlatformException
          ? (error.message ?? 'The radio stopped responding')
          : 'The radio stopped responding',
    ));
  }

  @override
  Future<void> startScan() => _invoke('startScan');

  @override
  Future<void> disconnect() => _invoke('disconnect');

  /// Wrapped against [MissingPluginException] for the reason
  /// `kore_platform.dart` gives: on a staged rollout the Dart half can
  /// legitimately know about a method the installed APK does not implement.
  /// That is a normal condition, and it must degrade rather than take down the
  /// frame that called it.
  Future<void> _invoke(String method) async {
    try {
      await commands.invokeMethod<void>(method);
    } on MissingPluginException {
      debugPrint('KORE: BLE host has no $method; ignoring');
    } on PlatformException catch (e) {
      debugPrint('KORE: BLE $method failed (${e.message}); ignoring');
    }
  }

  @override
  void dispose() {
    _hostStream?.cancel();
    _packets.close();
    _events.close();
  }
}
