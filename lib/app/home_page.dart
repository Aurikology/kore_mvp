import 'package:flutter/material.dart';

import '../dsp/cognitive_load_index.dart';
import '../services/history_store.dart';
import '../session/kore_session.dart';
import '../theme/kore_theme.dart';
import '../widgets/check_in_sheet.dart';
import '../widgets/load_meter.dart';
import '../widgets/load_sparkline.dart';
import '../widgets/recovery_card.dart';
import '../widgets/reset_protocol_sheet.dart';

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
          builder: (context, _) => _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final calibrating = !_session.isCalibrated;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
              horizontal: KoreSpace.xxl, vertical: KoreSpace.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context),
              const SizedBox(height: KoreSpace.xs),
              Center(
                child: LoadMeter(
                  value: _session.cognitiveLoad,
                  calibrating: calibrating,
                  calibrationSecondsRemaining:
                      _session.calibrationSecondsRemaining,
                  strainThreshold: CognitiveLoadIndex.kStrainEnter,
                  size: 200,
                ),
              ),
              const SizedBox(height: KoreSpace.sm),
              Center(child: _stateChip(context)),
              const SizedBox(height: KoreSpace.lg),
              _trendCard(context),
              const SizedBox(height: KoreSpace.md),
              if (_session.resetHistory.completedCount > 0) ...[
                RecoveryCard(
                  history: _session.resetHistory,
                  today: DateTime.now(),
                ),
                const SizedBox(height: KoreSpace.md),
              ],
              _resetCta(context),
              const SizedBox(height: KoreSpace.lg),
              _demoControls(text),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final text = Theme.of(context).textTheme;

    return Row(
      children: [
        Text('KORE', style: text.headlineLarge?.copyWith(letterSpacing: 1.5)),
        const Spacer(),
        // Never let the demo imply hardware that is not attached, or a native
        // path that is not actually running.
        _badge(context, _session.sourceLabel),
        const SizedBox(width: KoreSpace.xs),
        _badge(context, _session.backendLabel),
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

    return Container(
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
          // nothing here depends on being able to tell the two tints apart.
          Flexible(child: Text(label, style: text.titleSmall?.copyWith(color: color))),
        ],
      ),
    );
  }

  Widget _trendCard(BuildContext context) {
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
                Text(
                    'strain threshold ${CognitiveLoadIndex.kStrainEnter.round()}',
                    style: text.labelSmall),
              ],
            ),
            const SizedBox(height: KoreSpace.xs),
            LoadSparkline(
              values: _session.history,
              height: KoreSparkline.height(context.koreWindow),
              thresholdLine: CognitiveLoadIndex.kStrainEnter,
            ),
          ],
        ),
      ),
    );
  }

  Widget _resetCta(BuildContext context) {
    final strain = _session.loadState == LoadState.strain;

    return Column(
      children: [
        if (strain)
          Padding(
            padding: const EdgeInsets.only(bottom: KoreSpace.sm),
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

  Widget _demoControls(TextTheme text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DEMO CONTROLS',
            style: text.labelMedium?.copyWith(letterSpacing: KoreType.trackedLabel)),
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
