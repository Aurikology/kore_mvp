import 'package:flutter/material.dart';

import '../services/signal_quality.dart';
import '../session/kore_session.dart';
import '../sources/source_link.dart';
import '../theme/kore_theme.dart';
import '../widgets/patch_diagram.dart';

/// Finding the patch, connecting to it, and checking it is actually reading.
///
/// Three states in one screen, never three screens: they are one task, and a
/// user who has to press Next between "found it" and "is it on properly" is
/// being asked to confirm something the app already knows.
///
/// The contact check is the state that matters and the one hardware demos
/// always skip. A poor electrode does not produce an obviously broken reading;
/// it produces a *plausible* one, because losing contact raises theta and
/// suppresses alpha, which is the cognitive-load signature exactly. So this
/// screen is where the product's honesty is enforced, and Continue stays
/// disabled until every pad that can be measured is reading.
///
/// Tone is instructive, never alarming: "press the left pad down until it
/// reads", not a warning triangle. There is no alarm colour in the palette and
/// this screen does not invent one.
class PairScreen extends StatefulWidget {
  final KoreSession session;

  /// Called once the patch is connected and every pad is seated.
  final VoidCallback onContinue;

  const PairScreen({
    super.key,
    required this.session,
    required this.onContinue,
  });

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  @override
  void initState() {
    super.initState();
    // Starting the session here rather than on the dashboard is the whole
    // reason the contact check can be live. `KoreSession.start()` is
    // idempotent, so the dashboard starting it again when it mounts costs
    // nothing.
    widget.session.start();
  }

  KoreSession get _session => widget.session;

  @override
  Widget build(BuildContext context) {
    final kore = context.kore;

    return Scaffold(
      backgroundColor: kore.canvas,
      body: SafeArea(
        // Same 720 px column as the dashboard's medium layout. A head diagram
        // 1200 px wide is not a clearer head diagram.
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: AnimatedBuilder(
              animation: _session,
              builder: (context, _) => Padding(
            padding: const EdgeInsets.fromLTRB(
                KoreSpace.xl, KoreSpace.lg, KoreSpace.xl, KoreSpace.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context),
                const SizedBox(height: KoreSpace.xxl),
                Expanded(child: _body(context)),
              ],
            ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final kore = context.kore;
    final text = Theme.of(context).textTheme;
    final patch = _session.patch;

    return Row(
      children: [
        Text('KORE', style: text.titleMedium?.copyWith(letterSpacing: 1.5)),
        const Spacer(),
        if (patch != null)
          Text(
            // A battery the device cannot report says so. Rendering an
            // unmeasured battery as full is the same lie as rendering an
            // unmeasured electrode as seated.
            patch.batteryMeasured
                ? '${patch.name} · ${patch.batteryPercent}%'
                : '${patch.name} · battery not reported',
            style: text.labelMedium?.copyWith(color: kore.textSecondary),
          ),
      ],
    );
  }

  Widget _body(BuildContext context) {
    return switch (_session.linkState) {
      SourceLinkState.idle => _searching(context, stopped: true),
      SourceLinkState.scanning => _searching(context, stopped: false),
      SourceLinkState.connecting => _connecting(context),
      SourceLinkState.reconnecting => _connecting(context),
      SourceLinkState.failed => _failed(context),
      SourceLinkState.streaming => _contactCheck(context),
    };
  }

  // --- searching / connecting ---------------------------------------------

  Widget _searching(BuildContext context, {required bool stopped}) {
    final text = Theme.of(context).textTheme;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const _SearchRing(),
        const SizedBox(height: KoreSpace.xxl),
        Text(stopped ? 'Not looking for a patch' : 'Looking for your patch',
            style: text.titleMedium),
        const SizedBox(height: KoreSpace.xxxl),
        SizedBox(
          height: 48,
          child: stopped
              ? ElevatedButton(
                  onPressed: () => _session.start(),
                  child: const Text('Look again'),
                )
              : TextButton(
                  onPressed: _session.disconnect,
                  child: const Text('Cancel'),
                ),
        ),
      ],
    );
  }

  Widget _connecting(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final name = _session.patch?.name ?? 'your patch';

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const _SearchRing(),
        const SizedBox(height: KoreSpace.xxl),
        Text('Connecting to $name', style: text.titleMedium),
      ],
    );
  }

  Widget _failed(BuildContext context) {
    final kore = context.kore;
    final text = Theme.of(context).textTheme;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(_session.link.failure ?? 'The patch could not be reached',
            style: text.titleMedium?.copyWith(color: kore.unmeasured),
            textAlign: TextAlign.center),
        const SizedBox(height: KoreSpace.xxl),
        SizedBox(
          height: 48,
          child: ElevatedButton(
            onPressed: () => _session.start(),
            child: const Text('Try again'),
          ),
        ),
      ],
    );
  }

  // --- contact check -------------------------------------------------------

  Widget _contactCheck(BuildContext context) {
    final kore = context.kore;
    final text = Theme.of(context).textTheme;
    final electrodes = _session.electrodes;
    final ready = _session.allPadsSeated;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Contact check',
            style: text.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: KoreSpace.xs),
        Text(
          'A pad that is not reading does not go quiet. It reads as strain, '
          'so KORE checks before it measures anything.',
          style: text.bodySmall?.copyWith(color: kore.textSecondary),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: KoreSpace.lg),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: PatchDiagram(electrodes: electrodes),
                ),
                const SizedBox(height: KoreSpace.lg),
                for (final e in electrodes) ...[
                  _ElectrodeRow(electrode: e),
                  const SizedBox(height: KoreSpace.xs),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: KoreSpace.md),
        // The reason the button is disabled, always visible when it is. A
        // greyed button with no explanation is a dead end the user is left to
        // reverse-engineer.
        if (!ready)
          Padding(
            padding: const EdgeInsets.only(bottom: KoreSpace.sm),
            child: Text(
              _blockingReason(electrodes),
              style: text.bodySmall?.copyWith(color: kore.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: ready ? widget.onContinue : null,
            child: const Text('Continue'),
          ),
        ),
      ],
    );
  }

  /// Names the pad, because "contact is poor" is not an instruction and
  /// "press the left pad down" is.
  static String _blockingReason(List<ElectrodeContact> electrodes) {
    final bad = electrodes.where((e) => e.needsAttention).toList();
    if (bad.isEmpty) return 'Waiting for a reading from the patch.';
    if (bad.length == 1) {
      final e = bad.first;
      return e.state == ElectrodeContactState.noContact
          ? '${e.label} is not reading. Press it down until it does.'
          : '${e.label} is reading weakly. Press it down a little further.';
    }
    return '${bad.map((e) => e.label.toLowerCase()).join(' and ')} are not '
        'reading yet. Press them down until they do.';
  }
}

/// The state word for a pad, plus its coupling where there is one.
class _ElectrodeRow extends StatelessWidget {
  final ElectrodeContact electrode;

  const _ElectrodeRow({required this.electrode});

  /// Words, not only colour. Every state is legible with the colour discarded,
  /// which is the same rule the load ramp is built to.
  static String wordFor(ElectrodeContactState state) => switch (state) {
        ElectrodeContactState.good => 'Good',
        ElectrodeContactState.weak => 'Weak',
        ElectrodeContactState.noContact => 'No contact',
        ElectrodeContactState.unmeasured => 'Not measured',
      };

  @override
  Widget build(BuildContext context) {
    final kore = context.kore;
    final text = Theme.of(context).textTheme;

    final colour = switch (electrode.state) {
      ElectrodeContactState.good => kore.calm,
      ElectrodeContactState.weak => kore.accent,
      ElectrodeContactState.noContact => kore.accent,
      ElectrodeContactState.unmeasured => kore.unmeasured,
    };

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: KoreSpace.md, vertical: KoreSpace.sm),
      decoration: BoxDecoration(
        color: kore.surface,
        borderRadius: BorderRadius.circular(KoreRadius.md),
        border: Border.all(color: kore.border),
      ),
      child: Row(
        children: [
          Expanded(child: Text(electrode.label, style: text.titleSmall)),
          Text(wordFor(electrode.state),
              style: text.labelLarge?.copyWith(color: colour)),
        ],
      ),
    );
  }
}

/// A ring that turns while the app is looking. The only animation on the
/// screen, and it is there because a scan with no motion behind it is
/// indistinguishable from a screen that has hung.
class _SearchRing extends StatefulWidget {
  const _SearchRing();

  @override
  State<_SearchRing> createState() => _SearchRingState();
}

class _SearchRingState extends State<_SearchRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kore = context.kore;

    return SizedBox(
      width: 96,
      height: 96,
      child: RotationTransition(
        turns: _spin,
        child: CustomPaint(
          painter: _RingPainter(colour: kore.accent, track: kore.border),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final Color colour;
  final Color track;

  _RingPainter({required this.colour, required this.track});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final centre = rect.center;
    final radius = size.shortestSide / 2 - 2;

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = track,
    );

    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: radius),
      -1.57,
      1.2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..color = colour,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.colour != colour || old.track != track;
}
