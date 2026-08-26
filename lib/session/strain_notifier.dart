import 'dart:async';

import 'package:flutter/foundation.dart';

import '../dsp/cognitive_load_index.dart';
import '../services/kore_platform.dart';
import 'kore_session.dart';

/// Decides when the notification tier speaks, and when it stays quiet.
///
/// `KorePlatform` can post a banner; this is what says whether one should
/// exist. Kept out of both the session and the widget tree on purpose: the
/// session is the read model and has no business knowing about banners, and a
/// widget cannot own a rule whose whole subject is what happens while no
/// widget is on screen.
///
/// ## What it will and will not do
///
/// **It speaks only when the app is not in front.** In the foreground the
/// dashboard is already stating the reading, in a gauge built to be read at
/// arm's length; a banner drawn over it is the same fact twice, and the second
/// one is noise.
///
/// **It does not escalate.** One notification per episode, updated in place,
/// never re-posted. `Not now` suppresses for the rest of the *episode* rather
/// than for a fixed interval - a ten-minute snooze would fire again into an
/// episode the user has already declined, which is escalation wearing a
/// politer name. The suppression lifts when the episode does, because the next
/// episode is a new fact.
///
/// **It withdraws rather than lingers.** The banner comes down when the
/// episode ends, when the user comes back to the app, and when a reset starts.
/// A notification asserting strain that outlives the strain is the same class
/// of lie as a sparkline drawn across minutes nobody measured.
///
/// ## The boundary this tier currently sits behind
///
/// `KoreSession.pause()` stops the source when the app is backgrounded, which
/// is the honest thing for it to do - a session whose timers the OS has
/// throttled to nothing is not measuring, and should not hold a subscription
/// open pretending otherwise. The consequence lands here: **nothing is
/// measured while the app is in the background**, so the only moment this can
/// truthfully post is the transition into the background with an episode
/// already live, and the reading it carries is the last one taken while the
/// app was in front.
///
/// That is stated rather than papered over. The alternative - a foreground
/// service holding the pipeline alive - would today be keeping a *simulator*
/// running in the background and calling the result a measurement. The
/// foreground service is the right answer the moment there is a radio for it
/// to hold open, and it drops in behind this class without changing the rules
/// above: what changes is how often [refresh] has something new to say, not
/// what it is allowed to say.
class StrainNotifier {
  final KoreSession session;
  final KorePlatform platform;

  final StreamController<void> _resetRequests =
      StreamController<void>.broadcast();
  StreamSubscription<NotificationAction>? _actionSubscription;

  bool _inForeground = true;
  bool _posted = false;
  bool _keepingScreenOn = false;

  /// The user said `Not now` about the episode currently running. Cleared when
  /// that episode ends, not on a timer.
  bool _suppressed = false;

  /// Whether the session was in strain at the last observation, so the end of
  /// an episode can be detected as a transition rather than polled.
  bool _wasStrained = false;

  /// Whether posting is permitted. Starts false and stays false until
  /// [requestPermission] is both called and granted: a refused permission is a
  /// normal answer, and everything here has to keep working without it.
  bool _permitted = false;

  /// Asked once per run, and only once. A user who says no is not asked again
  /// by anything here; the OS settings screen is where that decision gets
  /// revisited, and re-prompting is how an app trains someone to deny it out
  /// of reflex.
  bool _permissionAsked = false;

  StrainNotifier({required this.session, KorePlatform? platform})
      : platform = platform ?? createKorePlatform() {
    _actionSubscription = this.platform.actions.listen(_onAction);
    session.addListener(_onSession);
  }

  /// Fired when the user presses `Reset` on the notification, or its body.
  /// The app wires this to the same entry point the dashboard button uses -
  /// the notification must not become a second, quietly different way to start
  /// a protocol.
  Stream<void> get resetRequests => _resetRequests.stream;

  bool get isSupported => platform.isSupported;

  /// Whether a banner is currently posted. For tests and for the debug
  /// overlay; nothing in the product reads it.
  @visibleForTesting
  bool get isPosted => _posted;

  @visibleForTesting
  bool get isSuppressed => _suppressed;

  /// Ask the platform for permission to post. Called automatically at the
  /// first strain episode; public so a settings screen can offer it again to
  /// someone who changed their mind.
  Future<bool> requestPermission() async {
    _permissionAsked = true;
    _permitted = await platform.requestNotificationPermission();
    // The answer can land after the app has already gone into the background -
    // the dialog is modal, and a user who grants it and immediately switches
    // away would otherwise wait out the whole episode in silence, because the
    // paused session produces no further frames to re-evaluate on.
    _refresh();
    return _permitted;
  }

  Future<void> _askOnce() async {
    if (_permissionAsked || !platform.isSupported) return;
    await requestPermission();
  }

  /// The app went into the background.
  ///
  /// The one moment this tier can currently speak. Called from the same
  /// lifecycle observer that drives `KoreSession.pause()`, and after it, so
  /// the reading it carries is the last measured one rather than one taken
  /// mid-teardown.
  void onBackgrounded() {
    _inForeground = false;
    _refresh();
  }

  /// The app is back in front. The banner is redundant the instant the gauge
  /// is visible again.
  void onForegrounded() {
    _inForeground = true;
    _clear();
  }

  void _onSession() {
    final strained = session.loadState == LoadState.strain;

    // Ask at the first episode, in the foreground, and never before.
    //
    // Not at launch: the first thing KORE shows is the claim boundary - what
    // it measures and what it is not - and a permission dialog stacked on that
    // asks for a capability the user has not yet been given a reason to want.
    // Here they have just watched the gauge latch into strain, which is the
    // only moment "tell me when this happens while I am away" explains itself.
    if (!_wasStrained && strained && _inForeground) {
      unawaited(_askOnce());
    }

    // The episode ended. Both the banner and the user's `Not now` belong to
    // that episode and end with it - carrying the suppression forward would
    // silence the next one, which the user never asked for.
    if (_wasStrained && !strained) {
      _suppressed = false;
      _clear();
    }
    _wasStrained = strained;

    // A reset in progress is the user already doing the thing the banner asks
    // for. Taking it down at the start of the protocol rather than at the end
    // means it is gone from the shade while they are breathing, not waiting
    // there for them afterwards.
    if (session.resetActive && _posted) _clear();

    _syncScreenOn();
    _refresh();
  }

  /// Post or update the banner if the rules allow one right now, and take it
  /// down otherwise. Idempotent, so it is safe to call on every frame.
  void _refresh() {
    if (!_shouldPost()) {
      if (_posted) _clear();
      return;
    }

    // Updating in place under the same notification id, which is what stops a
    // second banner appearing. See the host implementation.
    _posted = true;
    unawaited(platform.showStrain(StrainNotification(
      load: session.cognitiveLoad,
      measuredFor: session.strainFor,
    )));
  }

  bool _shouldPost() {
    if (!platform.isSupported || !_permitted) return false;
    if (_inForeground) return false;
    if (_suppressed) return false;
    if (session.resetActive) return false;
    if (session.loadState != LoadState.strain) return false;
    // The reading has to be one worth asserting. Strain is already withdrawn
    // when the signal goes unusable, so this is belt and braces - but the
    // failure it guards against is the whole reason the quality path exists,
    // and a notification is the one surface the user cannot see the caveat on.
    if (!session.isReadingTrustworthy) return false;
    return true;
  }

  void _clear() {
    if (!_posted) return;
    _posted = false;
    unawaited(platform.clearStrain());
  }

  /// Hold the display awake for the length of the protocol only.
  ///
  /// The reset is 60 s of following an animation without touching the screen,
  /// so the display timeout would put the phone to sleep partway through the
  /// one interaction the product is built around. Scoped to the protocol and
  /// released the moment it ends - the flag is not something to leave set.
  void _syncScreenOn() {
    final wanted = session.resetActive;
    if (wanted == _keepingScreenOn) return;
    _keepingScreenOn = wanted;
    unawaited(platform.setKeepScreenOn(wanted));
  }

  void _onAction(NotificationAction action) {
    switch (action) {
      case NotificationAction.reset:
        _clear();
        _resetRequests.add(null);
      case NotificationAction.dismiss:
        // For the rest of the episode. See the class comment.
        _suppressed = true;
        _clear();
    }
  }

  void dispose() {
    session.removeListener(_onSession);
    _actionSubscription?.cancel();
    _resetRequests.close();
    // Never leave the flag set on the way out.
    if (_keepingScreenOn) unawaited(platform.setKeepScreenOn(false));
    platform.dispose();
  }
}
