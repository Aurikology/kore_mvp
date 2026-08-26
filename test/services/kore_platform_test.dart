import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/services/kore_platform.dart';

/// Pretend the host invoked a method on the Dart side of the channel, exactly
/// as the Android notification receiver does.
Future<void> _hostInvokes(MethodCall call) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    AndroidKorePlatform.channel.name,
    const StandardMethodCodec().encodeMethodCall(call),
    (_) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the notification copy', () {
    test('states the load and the whole minutes it has lasted', () {
      const n = StrainNotification(
          load: 78.0, measuredFor: Duration(minutes: 6, seconds: 14));
      expect(n.body, 'Load 78 for the last 6 minutes');
    });

    test('says "1 minute", never "1 minutes"', () {
      const n = StrainNotification(
          load: 78.0, measuredFor: Duration(minutes: 1, seconds: 59));
      expect(n.body, 'Load 78 for the last 1 minute');
    });

    test('says "the last minute" under a minute rather than counting seconds',
        () {
      const n =
          StrainNotification(load: 78.0, measuredFor: Duration(seconds: 5));
      expect(n.body, 'Load 78 for the last minute',
          reason: 'the seconds are already wrong by the time it is read');

      const zero = StrainNotification(load: 78.0, measuredFor: Duration.zero);
      expect(zero.body, 'Load 78 for the last minute');
    });

    test('invents no duration when there is none to state', () {
      const n = StrainNotification(load: 78.0);
      expect(n.body, 'Load 78');
    });

    test('rounds the load where it is rendered, keeping the measurement', () {
      const n = StrainNotification(
          load: 77.6, measuredFor: Duration(minutes: 2));
      expect(n.body, 'Load 78 for the last 2 minutes');
      expect(n.load, 77.6, reason: 'the caller still holds the measurement');

      expect(const StrainNotification(load: 77.4).body, 'Load 77');
      expect(const StrainNotification(load: 77.5).body, 'Load 78');
    });
  });

  group('the calls the Android host receives', () {
    late List<MethodCall> log;
    late AndroidKorePlatform platform;

    /// Everything the host was asked, minus the cold-start drain the
    /// constructor always issues. That call is the subject of its own group
    /// below; here it is noise in front of the call under test.
    List<MethodCall> sent() =>
        log.where((c) => c.method != 'takePendingAction').toList();

    setUp(() {
      log = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidKorePlatform.channel,
              (MethodCall call) async {
        log.add(call);
        return null;
      });
      platform = AndroidKorePlatform();
    });

    tearDown(() {
      platform.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidKorePlatform.channel, null);
    });

    test('a build with a host says so', () {
      expect(platform.isSupported, isTrue);
    });

    test('showStrain sends the rendered body and nothing else', () async {
      await platform.showStrain(const StrainNotification(
          load: 78.4, measuredFor: Duration(minutes: 6)));

      expect(sent(), hasLength(1));
      expect(sent().single.method, 'showStrain');
      expect(sent().single.arguments,
          {'body': 'Load 78 for the last 6 minutes'},
          reason: 'the rendered copy crosses, not a second copy of the number');
    });

    test('a second showStrain updates in place rather than escalating',
        () async {
      await platform.showStrain(const StrainNotification(load: 72.0));
      await platform.showStrain(const StrainNotification(load: 81.0));

      expect(sent().map((c) => c.method), ['showStrain', 'showStrain'],
          reason: 'one method, not a post-and-then-post-another pair');
    });

    test('clearStrain sends its method with no arguments', () async {
      await platform.clearStrain();

      expect(sent().single.method, 'clearStrain');
      expect(sent().single.arguments, isNull);
    });

    test('setKeepScreenOn sends the flag both ways', () async {
      await platform.setKeepScreenOn(true);
      await platform.setKeepScreenOn(false);

      expect(sent().map((c) => c.method), ['setKeepScreenOn', 'setKeepScreenOn']);
      expect(sent().first.arguments, {'on': true});
      expect(sent().last.arguments, {'on': false});
    });

    test('a permission the host grants comes back as granted', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              AndroidKorePlatform.channel, (call) async => true);

      expect(await platform.requestNotificationPermission(), isTrue);
    });

    test('a host that answers nothing at all reads as not granted', () async {
      // The mock above returns null for every method.
      expect(await platform.requestNotificationPermission(), isFalse,
          reason: 'refused is the safe reading of an unanswered question');
    });
  });

  group('an action arriving from the host', () {
    late AndroidKorePlatform platform;
    late List<NotificationAction> received;

    setUp(() {
      received = <NotificationAction>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              AndroidKorePlatform.channel, (call) async => null);
      platform = AndroidKorePlatform();
      platform.actions.listen(received.add);
    });

    tearDown(() {
      platform.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidKorePlatform.channel, null);
    });

    test('"reset" reaches the app as a reset', () async {
      await _hostInvokes(const MethodCall('onAction', 'reset'));
      await pumpEventQueue();

      expect(received, [NotificationAction.reset]);
    });

    test('"dismiss" reaches the app as a dismiss', () async {
      await _hostInvokes(const MethodCall('onAction', 'dismiss'));
      await pumpEventQueue();

      expect(received, [NotificationAction.dismiss]);
    });

    test('both arrive, in the order the user pressed them', () async {
      await _hostInvokes(const MethodCall('onAction', 'dismiss'));
      await _hostInvokes(const MethodCall('onAction', 'reset'));
      await pumpEventQueue();

      expect(received,
          [NotificationAction.dismiss, NotificationAction.reset]);
    });

    test('an action this Dart does not know is dropped, never guessed',
        () async {
      await _hostInvokes(const MethodCall('onAction', 'snooze'));
      await _hostInvokes(const MethodCall('onAction', null));
      await pumpEventQueue();

      expect(received, isEmpty,
          reason: 'guessing reset starts a protocol nobody asked for, and '
              'guessing dismiss silences one they wanted');
    });

    test('a method that is not onAction is ignored', () async {
      await _hostInvokes(const MethodCall('somethingElse', 'reset'));
      await pumpEventQueue();

      expect(received, isEmpty);
    });
  });

  group('a host with no handler for a method', () {
    late AndroidKorePlatform platform;

    void answerWith(Object error) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidKorePlatform.channel,
              (call) async => throw error);
    }

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              AndroidKorePlatform.channel, (call) async => null);
      platform = AndroidKorePlatform();
    });

    tearDown(() {
      platform.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidKorePlatform.channel, null);
    });

    test('costs a log line rather than the frame that called it', () async {
      // An installed APK older than this Dart half: the method exists here and
      // has no handler there. That is a normal condition on a staged rollout.
      answerWith(MissingPluginException('no handler'));

      await expectLater(
          platform.showStrain(const StrainNotification(load: 78.0)),
          completes);
      await expectLater(platform.clearStrain(), completes);
      await expectLater(platform.setKeepScreenOn(true), completes);
      expect(await platform.requestNotificationPermission(), isFalse);
    });

    test('is no different when the host fails outright', () async {
      answerWith(PlatformException(code: 'BOOM', message: 'host blew up'));

      await expectLater(
          platform.showStrain(const StrainNotification(load: 78.0)),
          completes);
      await expectLater(platform.clearStrain(), completes);
      await expectLater(platform.setKeepScreenOn(false), completes);
      expect(await platform.requestNotificationPermission(), isFalse);
    });
  });

  group('a build with no host at all', () {
    test('reports itself unsupported rather than pretending', () {
      // The host VM is neither Android nor web, which is the desktop case the
      // fallback exists for.
      expect(createKorePlatform().isSupported, isFalse);
    });

    test('every call on it is a safe no-op', () async {
      final platform = createKorePlatform();

      await expectLater(
          platform.showStrain(const StrainNotification(
              load: 78.0, measuredFor: Duration(minutes: 6))),
          completes);
      await expectLater(platform.clearStrain(), completes);
      await expectLater(platform.setKeepScreenOn(true), completes);
      expect(await platform.requestNotificationPermission(), isFalse);
      await expectLater(platform.actions, emitsDone);

      platform.dispose();
    });
  });

  group('a press that landed before the app was running', () {
    // The race the pull design exists for: a PendingIntent fires and the
    // process is created *by* the press, so the host has an action in hand
    // before Dart has a handler to receive it. A host that pushed at engine
    // attach would fire into nothing and the press would vanish - which is
    // exactly the failure that makes a notification tier untrustworthy.

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidKorePlatform.channel, null);
    });

    test('is drained on the way up rather than waiting to be pushed', () async {
      var asked = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidKorePlatform.channel,
              (call) async {
        if (call.method != 'takePendingAction') return null;
        asked++;
        // Queued once, handed over once - the host clears it as it answers.
        return asked == 1 ? 'reset' : null;
      });

      final platform = AndroidKorePlatform();
      final seen = <NotificationAction>[];
      platform.actions.listen(seen.add);

      await pumpEventQueue();

      expect(asked, 1, reason: 'asked once, on the way up');
      expect(seen, [NotificationAction.reset]);

      platform.dispose();
    });

    test('an empty queue is the ordinary case and emits nothing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              AndroidKorePlatform.channel, (call) async => null);

      final platform = AndroidKorePlatform();
      final seen = <NotificationAction>[];
      platform.actions.listen(seen.add);

      await pumpEventQueue();

      expect(seen, isEmpty);
      platform.dispose();
    });

    test('a host too old to know the method costs nothing', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidKorePlatform.channel,
              (call) async {
        throw MissingPluginException('no such method');
      });

      final platform = AndroidKorePlatform();
      final seen = <NotificationAction>[];
      platform.actions.listen(seen.add);

      await pumpEventQueue();

      expect(seen, isEmpty, reason: 'a missing method is not an action');
      platform.dispose();
    });
  });
}
