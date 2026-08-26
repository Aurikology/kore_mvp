import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/services/kore_platform.dart';
import 'package:kore/session/kore_session.dart';
import 'package:kore/session/strain_notifier.dart';
import 'package:kore/sources/simulated_eeg_source.dart';

/// A host that records instead of posting.
///
/// [granted] is a constructor argument rather than a setter because a refused
/// permission is the case most likely to be got wrong, and it has to be
/// arrangeable before the first frame.
class _FakePlatform implements KorePlatform {
  final bool granted;
  final bool supported;

  _FakePlatform({this.granted = true, this.supported = true});

  final StreamController<NotificationAction> _actions =
      StreamController<NotificationAction>.broadcast();

  final List<String> calls = [];
  final List<String> bodies = [];
  int permissionRequests = 0;
  bool? screenOn;

  void press(NotificationAction action) => _actions.add(action);

  @override
  Stream<NotificationAction> get actions => _actions.stream;

  @override
  bool get isSupported => supported;

  @override
  Future<bool> requestNotificationPermission() async {
    permissionRequests++;
    return granted;
  }

  @override
  Future<void> showStrain(StrainNotification notification) async {
    calls.add('show');
    bodies.add(notification.body);
  }

  @override
  Future<void> clearStrain() async => calls.add('clear');

  @override
  Future<void> setKeepScreenOn(bool on) async {
    calls.add('screen:$on');
    screenOn = on;
  }

  @override
  void dispose() => _actions.close();
}

KoreSession _session(FakeAsync async) => KoreSession(
      source: SimulatedEegSource(
        elapsedMicros: () => async.elapsed.inMicroseconds,
      ),
      engine: DartDspEngine(),
    );

void _advance(FakeAsync async, Duration d) {
  async.elapse(d);
  async.flushMicrotasks();
}

/// A calibrated session sitting in a latched strain episode - the state every
/// rule here is about.
({KoreSession session, StrainNotifier notifier, _FakePlatform platform})
    _strained(FakeAsync async, {_FakePlatform? platform}) {
  final host = platform ?? _FakePlatform();
  final session = _session(async);
  final notifier = StrainNotifier(session: session, platform: host);

  session.start();
  async.flushMicrotasks();
  _advance(async, const Duration(seconds: 25));
  expect(session.isCalibrated, isTrue);

  session.simulateStrain();
  _advance(async, const Duration(seconds: 40));
  expect(session.loadState, LoadState.strain,
      reason: 'the rig has to reach the state the rules are about');

  return (session: session, notifier: notifier, platform: host);
}

void main() {
  group('the notification tier', () {
    test('says nothing while the app is in front of the user', () {
      fakeAsync((async) {
        final rig = _strained(async);

        expect(rig.notifier.isPosted, isFalse,
            reason: 'the dashboard is already stating the reading');
        expect(rig.platform.calls, isNot(contains('show')));

        rig.notifier.dispose();
        rig.session.dispose();
      });
    });

    test('posts the measurement when the app goes into the background', () {
      fakeAsync((async) {
        final rig = _strained(async);
        rig.notifier.onBackgrounded();

        expect(rig.notifier.isPosted, isTrue);
        expect(rig.platform.bodies.last, startsWith('Load '));
        expect(rig.platform.bodies.last, contains('for the last'),
            reason: 'the copy states the duration, not just the number');

        rig.notifier.dispose();
        rig.session.dispose();
      });
    });

    test('takes it down again the moment the user comes back', () {
      fakeAsync((async) {
        final rig = _strained(async);
        rig.notifier.onBackgrounded();
        expect(rig.notifier.isPosted, isTrue);

        rig.notifier.onForegrounded();
        expect(rig.notifier.isPosted, isFalse);
        expect(rig.platform.calls.last, 'clear');

        rig.notifier.dispose();
        rig.session.dispose();
      });
    });

    test('does not post for a steady reading', () {
      fakeAsync((async) {
        final platform = _FakePlatform();
        final session = _session(async);
        final notifier = StrainNotifier(session: session, platform: platform);
        session.start();
        async.flushMicrotasks();
        _advance(async, const Duration(seconds: 25));

        session.simulateCalm();
        _advance(async, const Duration(seconds: 20));
        expect(session.loadState, isNot(LoadState.strain));

        notifier.onBackgrounded();
        expect(notifier.isPosted, isFalse);

        notifier.dispose();
        session.dispose();
      });
    });

    test('never posts without permission, and asks only once', () {
      fakeAsync((async) {
        final platform = _FakePlatform(granted: false);
        final rig = _strained(async, platform: platform);

        expect(platform.permissionRequests, 1,
            reason: 'asked at the first episode, in the foreground');

        rig.notifier.onBackgrounded();
        expect(rig.notifier.isPosted, isFalse,
            reason: 'a refusal is a normal answer and must not be worked '
                'around');
        expect(platform.calls, isNot(contains('show')));

        // A second episode must not re-prompt.
        rig.session.simulateCalm();
        _advance(async, const Duration(seconds: 40));
        rig.notifier.onForegrounded();
        rig.session.simulateStrain();
        _advance(async, const Duration(seconds: 40));
        expect(platform.permissionRequests, 1);

        rig.notifier.dispose();
        rig.session.dispose();
      });
    });

    test('is inert on a platform with no host at all', () {
      fakeAsync((async) {
        final platform = _FakePlatform(supported: false);
        final rig = _strained(async, platform: platform);

        rig.notifier.onBackgrounded();
        expect(rig.notifier.isPosted, isFalse);
        expect(platform.permissionRequests, 0,
            reason: 'nothing to ask permission of');
        expect(platform.calls, isNot(contains('show')));

        rig.notifier.dispose();
        rig.session.dispose();
      });
    });
  });

  group('Not now', () {
    test('suppresses for the rest of the episode', () {
      fakeAsync((async) {
        final rig = _strained(async);
        rig.notifier.onBackgrounded();
        expect(rig.notifier.isPosted, isTrue);

        rig.platform.press(NotificationAction.dismiss);
        async.flushMicrotasks();

        expect(rig.notifier.isSuppressed, isTrue);
        expect(rig.notifier.isPosted, isFalse);

        // The episode continues, and nothing re-posts into it.
        _advance(async, const Duration(seconds: 60));
        expect(rig.session.loadState, LoadState.strain);
        expect(rig.notifier.isPosted, isFalse,
            reason: 're-posting into a declined episode is escalation');

        rig.notifier.dispose();
        rig.session.dispose();
      });
    });

    test('lifts when the episode ends, because the next one is a new fact', () {
      fakeAsync((async) {
        final rig = _strained(async);
        rig.notifier.onBackgrounded();
        rig.platform.press(NotificationAction.dismiss);
        async.flushMicrotasks();
        expect(rig.notifier.isSuppressed, isTrue);

        // The session has to run to end the episode, and it only runs in the
        // foreground - which is the boundary this tier sits behind today.
        rig.notifier.onForegrounded();
        rig.session.simulateCalm();
        _advance(async, const Duration(seconds: 60));
        expect(rig.session.loadState, isNot(LoadState.strain));
        expect(rig.notifier.isSuppressed, isFalse);

        rig.session.simulateStrain();
        _advance(async, const Duration(seconds: 40));
        expect(rig.session.loadState, LoadState.strain);
        rig.notifier.onBackgrounded();
        expect(rig.notifier.isPosted, isTrue,
            reason: 'a new episode is entitled to be stated');

        rig.notifier.dispose();
        rig.session.dispose();
      });
    });
  });

  group('Reset', () {
    test('is routed out as a request rather than started here', () {
      fakeAsync((async) {
        final rig = _strained(async);
        rig.notifier.onBackgrounded();

        var requests = 0;
        rig.notifier.resetRequests.listen((_) => requests++);
        rig.platform.press(NotificationAction.reset);
        async.flushMicrotasks();

        expect(requests, 1);
        expect(rig.notifier.isPosted, isFalse,
            reason: 'the banner has been acted on and should leave the shade');

        rig.notifier.dispose();
        rig.session.dispose();
      });
    });

    test('an unknown action from a newer host is dropped, never guessed', () {
      fakeAsync((async) {
        final rig = _strained(async);
        rig.notifier.onBackgrounded();

        var requests = 0;
        rig.notifier.resetRequests.listen((_) => requests++);
        async.flushMicrotasks();

        expect(requests, 0);
        expect(rig.notifier.isSuppressed, isFalse);

        rig.notifier.dispose();
        rig.session.dispose();
      });
    });
  });

  group('the screen during a reset', () {
    test('is held awake for the protocol and released at the end', () {
      fakeAsync((async) {
        final rig = _strained(async);

        rig.session.startReset();
        async.flushMicrotasks();
        expect(rig.platform.screenOn, isTrue,
            reason: '60 s of watching an animation outlasts the display '
                'timeout');

        _advance(async, const Duration(seconds: 65));
        expect(rig.session.resetActive, isFalse);
        expect(rig.platform.screenOn, isFalse,
            reason: 'the flag is not something to leave set');

        rig.notifier.dispose();
        rig.session.dispose();
      });
    });

    test('is released when the protocol is abandoned, not only completed', () {
      fakeAsync((async) {
        final rig = _strained(async);

        rig.session.startReset();
        async.flushMicrotasks();
        expect(rig.platform.screenOn, isTrue);

        _advance(async, const Duration(seconds: 5));
        rig.session.cancelReset();
        async.flushMicrotasks();
        expect(rig.platform.screenOn, isFalse);

        rig.notifier.dispose();
        rig.session.dispose();
      });
    });

    test('a reset takes the banner down while it runs', () {
      fakeAsync((async) {
        final rig = _strained(async);
        rig.notifier.onBackgrounded();
        expect(rig.notifier.isPosted, isTrue);

        rig.session.startReset();
        async.flushMicrotasks();

        expect(rig.notifier.isPosted, isFalse,
            reason: 'the user is already doing what it asked for');

        rig.notifier.dispose();
        rig.session.dispose();
      });
    });
  });
}
