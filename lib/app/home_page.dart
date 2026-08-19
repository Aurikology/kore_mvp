import 'package:flutter/material.dart';

import '../dsp/cognitive_load_index.dart';
import '../services/history_store.dart';
import '../session/kore_session.dart';
import '../theme/kore_theme.dart';
import '../widgets/check_in_sheet.dart';
import '../widgets/forecast_notice.dart';
import '../widgets/load_meter.dart';
import '../widgets/load_sparkline.dart';
import '../widgets/recovery_card.dart';
import '../widgets/reset_protocol_sheet.dart';

/// The live dashboard.
///
/// Three layouts off one widget list, chosen by window class rather than by
/// platform - a 500 px desktop window gets the phone layout, which is what
/// someone who has parked KORE beside their work actually wants. See
/// `docs/design/mobile.md`.
class HomePage extends StatefulWidget {
  final HistoryStore? store;

  const HomePage({super.key, this.store});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final KoreSession _session;

  @override
  void initState() {
    super.initState();
    _session = KoreSession(store: widget.store);
    _session.start();
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  Future<void> _openReset() async {
    // Start before pushing: doing it from the sheet's initState would fire
    // notifyListeners() mid-build.
    _session.startReset();
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => ResetProtocolSheet(session: _session),
      ),
    );
    // Covers the system back gesture, which pops the route without going
    // through either exit path in the sheet.
    if (_session.resetActive) _session.cancelReset();
    if (!mounted) return;

    if (_session.awaitingCheckIn) {
      final clarity = await showModalBottomSheet<int>(
        context: context,
        showDragHandle: true,
        // The sheet is a single question; on a tall phone a half-height sheet
        // would leave the options stranded under the thumb's reach.
        isScrollControlled: true,
        builder: (_) => CheckInSheet(drop: _session.pendingDrop),
      );
      // Dismissing by tapping outside returns null, same as Skip: the reset is
      // still logged, just without a self-report.
      await _session.commitReset(clarity: clarity);
    } else {
      await _session.commitReset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _session,
          // Classified off the constraints rather than the window, so the
          // dashboard is correct inside any box it is given - including a
          // test harness that has not resized the view.
          builder: (context, _) => LayoutBuilder(
            builder: (context, constraints) => switch (
                KoreBreakpoints.classify(constraints.biggest)) {
              KoreWindow.compact => _compact(context),
              KoreWindow.medium => _column(context, KoreWindow.medium),
              KoreWindow.expanded => _expanded(context),
            },
          ),
        ),
      ),
    );
  }

  // --- Layouts -------------------------------------------------------------

  /// Phone. The reset is pinned to the bottom bar rather than left at the end
  /// of the scroll: it is the only thing on this screen a user acts on, and
  /// on a phone held one-handed the bottom third is the only comfortable
  /// place for it. Everything else scrolls past it.
  Widget _compact(BuildContext context) {
    final gutter = KoreBreakpoints.gutter(KoreWindow.compact);

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
                gutter, KoreSpace.sm, gutter, KoreSpace.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ..._headline(context, KoreWindow.compact),
                const SizedBox(height: KoreSpace.lg),
                ..._detail(context, KoreWindow.compact),
              ],
            ),
          ),
        ),
        _bottomBar(context, gutter),
      ],
    );
  }

  /// Tablet, split screen, or a modest desktop window. One column, capped so
  /// the gauge and the trend stay in the same glance.
  Widget _column(BuildContext context, KoreWindow window) {
    final gutter = KoreBreakpoints.gutter(window);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
              horizontal: gutter, vertical: KoreSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ..._headline(context, window),
              const SizedBox(height: KoreSpace.lg),
              _resetCta(context),
              const SizedBox(height: KoreSpace.lg),
              ..._detail(context, window),
            ],
          ),
        ),
      ),
    );
  }

  /// Desktop. Reading left to right: the state now, then the history behind
  /// it. Two columns rather than one long scroll, because a desktop window
  /// has the width and a scroll costs a glance.
  Widget _expanded(BuildContext context) {
    final gutter = KoreBreakpoints.gutter(KoreWindow.expanded);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
              horizontal: gutter, vertical: KoreSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context, KoreWindow.expanded),
              const SizedBox(height: KoreSpace.xl),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Column(
                      children: [
                        _gauge(context, KoreWindow.expanded),
                        const SizedBox(height: KoreSpace.sm),
                        _stateChip(context),
                        const SizedBox(height: KoreSpace.xl),
                        _resetCta(context),
                      ],
                    ),
                  ),
                  const SizedBox(width: KoreSpace.xxl),
                  Expanded(
                    flex: 6,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _detail(context, KoreWindow.expanded),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Shared blocks -------------------------------------------------------

  /// Identity, then the reading. The order the eye wants on every surface.
  List<Widget> _headline(BuildContext context, KoreWindow window) => [
        _header(context, window),
        const SizedBox(height: KoreSpace.md),
        _gauge(context, window),
        const SizedBox(height: KoreSpace.sm),
        _stateChip(context),
      ];

  /// Everything behind the reading. Same list on every layout; only where it
  /// sits changes.
  List<Widget> _detail(BuildContext context, KoreWindow window) => [
        _trendCard(context, window),
        if (_session.resetHistory.completedCount > 0) ...[
          const SizedBox(height: KoreSpace.md),
          RecoveryCard(history: _session.resetHistory, today: DateTime.now()),
        ],
        const SizedBox(height: KoreSpace.lg),
        _demoControls(context),
      ];

  Widget _gauge(BuildContext context, KoreWindow window) {
    return LayoutBuilder(
      builder: (context, constraints) => Center(
        child: LoadMeter(
          value: _session.cognitiveLoad,
          calibrating: !_session.isCalibrated,
          calibrationSecondsRemaining: _session.calibrationSecondsRemaining,
          strainThreshold: _session.strainEnter,
          size: KoreGauge.diameterFor(constraints.maxWidth, window),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, KoreWindow window) {
    final text = Theme.of(context).textTheme;
    final title =
        Text('KORE', style: text.headlineLarge?.copyWith(letterSpacing: 1.5));

    // Never let the demo imply hardware that is not attached, or a native
    // path that is not actually running.
    final badges = [
      _badge(context, _session.sourceLabel),
      _badge(context, _session.backendLabel),
    ];

    // On a phone the two badges plus the wordmark do not fit on one line
    // once the native backend is running - "Native DSP (C++)" is half the
    // width on its own. They get their own row rather than being truncated.
    if (window == KoreWindow.compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title,
          const SizedBox(height: KoreSpace.xs),
          Wrap(spacing: KoreSpace.xs, runSpacing: KoreSpace.xxs, children: badges),
        ],
      );
    }

    return Row(
      children: [
        title,
        const Spacer(),
        badges.first,
        const SizedBox(width: KoreSpace.xs),
        badges.last,
      ],
    );
  }

  Widget _badge(BuildContext context, String label) {
    final k = context.kore;

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: KoreSpace.sm, vertical: KoreSpace.xxs),
      decoration: BoxDecoration(
        color: k.card,
        borderRadius: BorderRadius.circular(KoreRadius.pill),
        border: Border.all(color: k.border),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: k.textSecondary, letterSpacing: 0.6),
      ),
    );
  }

  Widget _stateChip(BuildContext context) {
    final k = context.kore;
    final text = Theme.of(context).textTheme;

    final (label, color) = switch (_session.loadState) {
      LoadState.calibrating => ('Establishing your baseline', k.unmeasured),
      LoadState.steady => ('Steady', k.calm),
      LoadState.strain => ('Strain detected', k.strain),
    };

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: KoreSpace.md, vertical: KoreSpace.xs),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(KoreRadius.pill),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: KoreSpace.xs),
            // The word is the state. The dot and the tint agree with it, but
            // nothing here depends on telling the two tints apart.
            Flexible(
              child: Text(label, style: text.titleSmall?.copyWith(color: color)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _trendCard(BuildContext context, KoreWindow window) {
    final text = Theme.of(context).textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            KoreSpace.lg, KoreSpace.md, KoreSpace.lg, KoreSpace.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('LAST 2 MINUTES',
                    style: text.labelMedium
                        ?.copyWith(letterSpacing: KoreType.trackedLabel)),
                const Spacer(),
                Flexible(
                  // "your threshold" only once it actually is theirs. Calling
                  // the default personal would claim the app had learned
                  // something about them in the first minute.
                  child: Text(
                    '${_session.thresholdsPersonalised ? 'your' : 'strain'} '
                    'threshold ${_session.strainEnter.round()}',
                    style: text.labelSmall,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
            const SizedBox(height: KoreSpace.xs),
            LoadSparkline(
              values: _session.history,
              height: KoreSparkline.height(window),
              thresholdLine: _session.strainEnter,
            ),
          ],
        ),
      ),
    );
  }

  /// The phone's persistent footer. Sits on the canvas with a hairline above
  /// so it reads as a shelf rather than as part of the scroll.
  Widget _bottomBar(BuildContext context, double gutter) {
    final k = context.kore;

    return Container(
      decoration: BoxDecoration(
        color: k.canvas,
        border: Border(top: BorderSide(color: k.border)),
      ),
      padding: EdgeInsets.fromLTRB(
          gutter, KoreSpace.sm, gutter, KoreSpace.sm),
      child: _resetCta(context),
    );
  }

  Widget _resetCta(BuildContext context) {
    final strain = _session.loadState == LoadState.strain;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Strain outranks the forecast: once the index has actually crossed,
        // "about 15 seconds out" is a statement about a future that already
        // arrived. Only one of the two ever shows.
        if (!strain) ForecastNotice(forecast: _session.crashForecast),
        // Appears above the button, never in place of anything, so the button
        // itself does not move when the state changes.
        if (strain)
          Padding(
            padding: const EdgeInsets.only(bottom: KoreSpace.xs),
            child: Text(
              'Reset recommended',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: context.kore.strain),
            ),
          ),
        SizedBox(
          height: 52,
          width: double.infinity,
          // Always enabled: waiting for the simulation to cross a threshold
          // before you can demo the reset would be a bad way to run a demo.
          child: ElevatedButton(
            onPressed: _openReset,
            child: const Text('Run a reset'),
          ),
        ),
      ],
    );
  }

  Widget _demoControls(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DEMO CONTROLS',
            style: text.labelMedium
                ?.copyWith(letterSpacing: KoreType.trackedLabel)),
        const SizedBox(height: KoreSpace.xs),
        Wrap(
          spacing: KoreSpace.xs,
          runSpacing: KoreSpace.xs,
          children: [
            OutlinedButton(
              onPressed: _session.simulateStrain,
              child: const Text('Simulate strain'),
            ),
            OutlinedButton(
              onPressed: _session.simulateCalm,
              child: const Text('Simulate calm'),
            ),
            OutlinedButton(
              onPressed: _session.recalibrate,
              child: const Text('Recalibrate'),
            ),
          ],
        ),
      ],
    );
  }
}
