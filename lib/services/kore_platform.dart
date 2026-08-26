import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The in-repo platform channel. No pub package, on purpose.
///
/// `docs/hardware-seam.md` makes the call this file is the first instance of:
/// the constraint is *no pub dependency*, not *no platform code*. A
/// [MethodChannel] written inside this repo adds nothing to `pubspec.yaml`,
/// needs no symlink support or Developer Mode on Windows, and loads nothing a
/// host-VM test has to bind. `package:flutter/services.dart` is part of the
/// framework, the same way `HapticFeedback` - already used by the reset
/// protocol - is.
///
/// The behaviour when there is no host implementation is copied deliberately
/// from `createDspEngine()`: try the platform, fall back to something inert,
/// and let a missing capability cost a log line rather than the app. Windows
/// has no notification host here, and the desktop build must not care.
///
/// This is also the precedent BLE follows. Getting the shape right where a
/// failure costs one missing banner is cheaper than discovering it with a
/// radio attached.

/// What the user pressed on the notification.
enum NotificationAction {
  /// The body of the notification, or its `Reset` button. Both mean the same
  /// thing: open the app and start the protocol.
  reset,

  /// `Not now`. Suppresses for the rest of the episode - not for ten minutes.
  /// A timed snooze would fire again into an episode the user has already
  /// declined, which is the escalation this tier promises not to do.
  dismiss,
}

/// A live strain reading, as the notification states it.
@immutable
class StrainNotification {
  /// The index. Rounded where it is rendered rather than here, so the caller
  /// keeps the measurement.
  final double load;

  /// How long the episode has been measured. Null renders the headline
  /// without a duration rather than inventing one.
  final Duration? measuredFor;

  const StrainNotification({required this.load, this.measuredFor});

  /// The fixed format from `docs/design/mobile.md`:
  ///
  ///     KORE - Load 78 for the last 6 minutes
  ///
  /// It states the measurement and the duration. It does not say "you seem
  /// stressed", does not use an emoji, and does not escalate if ignored.
  ///
  /// Whole minutes, because a notification is read at a glance: "6 minutes" is
  /// the fact, and "6 minutes 14 seconds" is the same fact costing more to
  /// read. Under a minute it says "the last minute" rather than a count of
  /// seconds - by the time the banner is on screen the seconds are already
  /// wrong, and a number that precise invites a precision the episode
  /// boundary does not have.
  String get body {
    final load = this.load.round();
    final measured = measuredFor;
    if (measured == null) return 'Load $load';
    final minutes = measured.inMinutes;
    if (minutes < 1) return 'Load $load for the last minute';
    return 'Load $load for the last $minutes '
        '${minutes == 1 ? "minute" : "minutes"}';
  }
}

/// The host side of the channel, as the app sees it.
abstract class KorePlatform {
  /// Actions arriving from a notification the user pressed. Broadcast, because
  /// more than one listener wants them and neither owns the other.
  Stream<NotificationAction> get actions;

  /// Ask for permission to post. Returns whether posting is allowed - false is
  /// a normal answer, not a failure, and every caller must keep working
  /// without it. Inert hosts return false.
  Future<bool> requestNotificationPermission();

  /// Post or update the strain notification. Updating in place rather than
  /// posting a second one is what "does not escalate if ignored" means at the
  /// platform level.
  Future<void> showStrain(StrainNotification notification);

  /// Take it down. Safe when nothing is showing.
  Future<void> clearStrain();

  /// Hold the screen on for the duration of the reset.
  ///
  /// The protocol is 60 s of following an animation without touching the
  /// screen, so the display timeout puts the phone to sleep partway through
  /// the one thing the product is built around. Scoped to the protocol and
  /// released at the end - an app that holds the screen open for its whole
  /// lifetime is a battery complaint.
  Future<void> setKeepScreenOn(bool on);

  /// Whether this build actually reached a host. False means every call above
  /// is inert, and the UI may say so rather than offering a control that does
  /// nothing.
  bool get isSupported;

  void dispose();
}

/// Returns the platform channel if this build has a host for it, and an inert
/// one otherwise.
///
/// Android is the only host today. Windows gets [_InertPlatform], which is why
/// the desktop build needs no conditionals anywhere downstream - the same
/// reason `createDspEngine()`'s fallback keeps `KoreSession` free of them.
KorePlatform createKorePlatform() {
  if (kIsWeb) return const _InertPlatform();
  try {
    if (Platform.isAndroid) return AndroidKorePlatform();
  } catch (e) {
    // `Platform` throws where there is no platform at all. Costing a log line,
    // not the app.
    debugPrint('KORE: platform channel unavailable ($e); notifications off');
  }
  return const _InertPlatform();
}

/// Every call succeeds and does nothing.
///
/// Deliberately not a thrown `UnsupportedError`. A caller that had to guard
/// each call would grow the same platform conditional in five places, which is
/// exactly what this file exists to hold in one.
class _InertPlatform implements KorePlatform {
  const _InertPlatform();

  @override
  Stream<NotificationAction> get actions => const Stream.empty();

  @override
  Future<bool> requestNotificationPermission() async => false;

  @override
  Future<void> showStrain(StrainNotification notification) async {}

  @override
  Future<void> clearStrain() async {}

  @override
  Future<void> setKeepScreenOn(bool on) async {}

  @override
  bool get isSupported => false;

  @override
  void dispose() {}
}

/// The Android host, over one [MethodChannel] in both directions.
///
/// Visible for testing: the test suite drives it through
/// `TestDefaultBinaryMessengerBinding`, which is how the copy, the call
/// sequence and the action decoding are all checked on the host VM with no
/// device attached.
@visibleForTesting
class AndroidKorePlatform implements KorePlatform {
  static const MethodChannel channel = MethodChannel('kore/platform');

  final StreamController<NotificationAction> _actions =
      StreamController<NotificationAction>.broadcast();

  AndroidKorePlatform() {
    channel.setMethodCallHandler(_onHostCall);
    // Ask, rather than waiting to be told.
    //
    // A notification button press arrives at the host as a PendingIntent, and
    // on a cold start that happens before this handler exists - the process is
    // being created *by* the press. A host that pushed the action at engine
    // attach would fire it into a channel with nothing listening, and a
    // `Reset` that vanishes because the app was not already running is exactly
    // the failure that makes a notification tier untrustworthy. So the host
    // queues it and this drains the queue at the first moment there is
    // somewhere for it to land.
    unawaited(_drainPending());
  }

  Future<void> _drainPending() async {
    final pending = await _invoke<String>('takePendingAction');
    if (pending != null) _emit(pending);
  }

  @override
  Stream<NotificationAction> get actions => _actions.stream;

  @override
  bool get isSupported => true;

  Future<dynamic> _onHostCall(MethodCall call) async {
    if (call.method != 'onAction') return null;
    _emit(call.arguments);
    return null;
  }

  void _emit(Object? action) {
    switch (action) {
      case 'reset':
        _actions.add(NotificationAction.reset);
      case 'dismiss':
        _actions.add(NotificationAction.dismiss);
      default:
        // An unknown action from a host build newer than this Dart. Dropped
        // rather than guessed: guessing `reset` would start a protocol nobody
        // asked for, and guessing `dismiss` would silence one they wanted.
        debugPrint('KORE: unknown notification action $action');
    }
  }

  @override
  Future<bool> requestNotificationPermission() async =>
      await _invoke<bool>('requestNotificationPermission') ?? false;

  @override
  Future<void> showStrain(StrainNotification notification) =>
      // Only the rendered body crosses. The host does not get the raw index
      // as well: it has no slot to put a bare number in that does not read as
      // something else, and a second copy of the same fact on the far side of
      // a channel is a second thing that can disagree with the first.
      _invoke<void>('showStrain', {'body': notification.body});

  @override
  Future<void> clearStrain() => _invoke<void>('clearStrain');

  @override
  Future<void> setKeepScreenOn(bool on) =>
      _invoke<void>('setKeepScreenOn', {'on': on});

  /// Every call goes through here for one reason: a channel throws
  /// [MissingPluginException] when the host has no handler for a method, and
  /// on a staged rollout of this file that is a *normal* condition - the Dart
  /// half can know about a method the installed APK does not implement. It has
  /// to degrade to the inert behaviour rather than taking down the frame that
  /// called it.
  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('KORE: platform call $method failed (${e.code}); ignoring');
      return null;
    }
  }

  @override
  void dispose() {
    channel.setMethodCallHandler(null);
    _actions.close();
  }
}
