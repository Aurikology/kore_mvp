import 'package:flutter/material.dart';

import '../services/history_store.dart';
import '../session/kore_session.dart';
import '../sources/simulated_eeg_source.dart';
import '../theme/kore_theme.dart';
import 'home_page.dart';
import 'pair_screen.dart';
import 'welcome_screen.dart';

/// Decides what the app opens on: the first-run flow, or the dashboard.
///
/// Welcome and Pair are shown once, ever. That "ever" is the whole contract,
/// and it is why this reads a persisted fact rather than a flag in memory:
/// a welcome screen that reappears is worse than one that never existed,
/// because the second time it reads as the app having forgotten the user.
///
/// The flow is not a wizard. There are two screens, no progress dots, and no
/// back button between them - the user is either being told what KORE claims,
/// or being helped to get the patch on. `docs/design/mobile.md` has the shape.
class KoreLaunch extends StatefulWidget {
  /// Null means nothing is remembered between runs. See [_decide].
  final HistoryStore? store;

  const KoreLaunch({super.key, this.store});

  @override
  State<KoreLaunch> createState() => _KoreLaunchState();
}

enum _Phase { deciding, welcome, pair, dashboard }

class _KoreLaunchState extends State<KoreLaunch> {
  _Phase _phase = _Phase.deciding;

  /// Built only for the first-run path, because the pairing screen needs a
  /// live source to check contact against. On the ordinary path the dashboard
  /// builds and owns its own, exactly as it did before this screen existed.
  KoreSession? _session;

  @override
  void initState() {
    super.initState();
    _decide();
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  Future<void> _decide() async {
    final store = widget.store;

    // No store means no memory, and a screen whose entire contract is "shown
    // once, ever" cannot be honoured by something that forgets. Rather than
    // show it on every run, this goes straight to the dashboard - the same
    // meaning `store == null` already carries through the rest of the app,
    // where it is what keeps widget tests off the user's AppData.
    if (store == null) {
      setState(() => _phase = _Phase.dashboard);
      return;
    }

    final done = await store.hasOnboarded();
    if (!mounted) return;
    setState(() => _phase = done ? _Phase.dashboard : _Phase.welcome);
  }

  void _startPairing() {
    setState(() {
      // Scan and connect delays are set here, at the composition root, rather
      // than defaulted in the source: everywhere else in the codebase the
      // simulated patch connects instantly, which is what keeps the test suite
      // free of pumping. A pairing screen is the one place where instant is
      // wrong - a scan that resolves in one frame cannot be cancelled, and
      // reads as a mock-up rather than as a device being found.
      _session = KoreSession(
        store: widget.store,
        source: SimulatedEegSource(
          scanDuration: const Duration(milliseconds: 1400),
          connectDuration: const Duration(milliseconds: 900),
        ),
      );
      _phase = _Phase.pair;
    });
  }

  Future<void> _finishOnboarding() async {
    // Written when the user leaves the pairing screen, not at the end of their
    // first session: the flow is done when they have seen it, and a crash
    // before the first reset is not a reason to show them the claim boundary
    // again.
    await widget.store?.markOnboarded(DateTime.now());
    if (!mounted) return;
    setState(() => _phase = _Phase.dashboard);
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _Phase.deciding:
        // One disk read. A blank canvas for a frame is better than a flash of
        // the wrong screen, which is what showing the dashboard optimistically
        // would cost a first-run user.
        return Scaffold(backgroundColor: context.kore.canvas);

      case _Phase.welcome:
        return WelcomeScreen(onContinue: _startPairing);

      case _Phase.pair:
        return PairScreen(
          session: _session!,
          onContinue: _finishOnboarding,
        );

      case _Phase.dashboard:
        // The session built for pairing carries straight through, already
        // connected and already calibrating. Handing the dashboard a fresh one
        // would throw away the contact check the user just passed and make
        // them wait through the scan again.
        return HomePage(store: widget.store, session: _session);
    }
  }
}
