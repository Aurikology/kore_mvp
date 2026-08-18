import 'package:flutter/material.dart';

import '../dsp/cognitive_load_index.dart';
import '../services/history_store.dart';
import '../session/kore_session.dart';
import '../theme.dart';
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
        backgroundColor: KoreTheme.surface,
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
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(text),
              const SizedBox(height: 8),
              Center(
                child: LoadMeter(
                  value: _session.cognitiveLoad,
                  calibrating: calibrating,
                  calibrationSecondsRemaining:
                      _session.calibrationSecondsRemaining,
                  size: 184,
                ),
              ),
              const SizedBox(height: 12),
              Center(child: _stateChip(text)),
              const SizedBox(height: 18),
              _trendCard(text),
              const SizedBox(height: 16),
              RecoveryCard(
                history: _session.resetHistory,
                today: DateTime.now(),
              ),
              _resetCta(),
              const SizedBox(height: 18),
              _demoControls(text),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(TextTheme text) {
    return Row(
      children: [
        Text('KORE', style: text.headlineLarge?.copyWith(letterSpacing: 1.5)),
        const Spacer(),
        // Never let the demo imply hardware that is not attached, or a native
        // path that is not actually running.
        _badge(_session.sourceLabel, KoreTheme.textSecondary),
        const SizedBox(width: 8),
        _badge(_session.backendLabel, KoreTheme.textSecondary),
      ],
    );
  }

  Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: KoreTheme.card,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: KoreTheme.border),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color, letterSpacing: 0.6),
      ),
    );
  }

  Widget _stateChip(TextTheme text) {
    final (label, color) = switch (_session.loadState) {
      LoadState.calibrating => (
          'Establishing your baseline',
          KoreTheme.textSecondary
        ),
      LoadState.steady => ('Steady', KoreTheme.sage),
      LoadState.strain => ('Strain detected', KoreTheme.rust),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
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
          const SizedBox(width: 10),
          Text(label, style: text.titleSmall?.copyWith(color: color)),
        ],
      ),
    );
  }

  Widget _trendCard(TextTheme text) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('LAST 2 MINUTES',
                    style: text.labelMedium?.copyWith(letterSpacing: 1.4)),
                const Spacer(),
                Text(
                    'strain threshold ${CognitiveLoadIndex.kStrainEnter.round()}',
                    style: text.labelSmall),
              ],
            ),
            const SizedBox(height: 10),
            LoadSparkline(
              values: _session.history,
              height: 64,
              thresholdLine: CognitiveLoadIndex.kStrainEnter,
            ),
          ],
        ),
      ),
    );
  }

  Widget _resetCta() {
    final strain = _session.loadState == LoadState.strain;

    return Column(
      children: [
        if (strain)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Reset recommended',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: KoreTheme.rust),
            ),
          ),
        SizedBox(
          height: 52,
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
            style: text.labelMedium?.copyWith(letterSpacing: 1.4)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 10,
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
