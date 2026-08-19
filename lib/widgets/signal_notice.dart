import 'package:flutter/material.dart';

import '../services/signal_quality.dart';
import '../theme/kore_theme.dart';

/// What is wrong with the signal, in the user's words, with the fix.
///
/// This exists because withholding a reading silently is its own kind of
/// dishonesty: a gauge that has quietly stopped updating looks exactly like a
/// user who has quietly stopped being strained. If KORE is going to refuse to
/// publish, it has to say so and say why.
///
/// Rendered in [KoreColors.unmeasured] rather than [KoreColors.strain]. The
/// distinction the palette draws is between colouring a *measurement* and
/// colouring a *fault*, and a fault is not a reading - painting it in the
/// strain colour would put a cognitive-load colour on something that is not
/// cognitive load, which is the exact confusion this whole path exists to
/// prevent.
class SignalNotice extends StatelessWidget {
  final SignalQualityLevel level;
  final Set<SignalFault> faults;

  /// Baseline capture is standing still because the signal is not clean enough
  /// to define one from. Worth saying out loud: the symptom on its own is a
  /// countdown that has stopped counting, which reads as a crash.
  final bool calibrationStalled;

  const SignalNotice({
    super.key,
    required this.level,
    required this.faults,
    this.calibrationStalled = false,
  });

  /// The worst fault decides the message. Ordered by what the user should do
  /// about it, not by severity: a detached electrode and poor contact have the
  /// same fix and different urgency, while a dropout has a different fix
  /// entirely and no amount of adjusting the electrode helps.
  static String? headline(Set<SignalFault> faults) {
    if (faults.contains(SignalFault.electrodeDetached)) {
      return 'The electrode is not making contact';
    }
    if (faults.contains(SignalFault.poorContact)) {
      return 'Electrode contact is weak';
    }
    if (faults.contains(SignalFault.dropout)) {
      return 'Samples are not arriving';
    }
    if (faults.contains(SignalFault.sampleRateDrift)) {
      return 'The signal is arriving off-rate';
    }
    if (faults.contains(SignalFault.settling)) {
      return 'Re-reading the signal';
    }
    return null;
  }

  /// The fix, where there is one the user can act on. `settling` deliberately
  /// has none - it clears on its own in about two seconds, and asking someone
  /// to do something about it would be asking them to fix the arithmetic.
  static String? action(Set<SignalFault> faults, {required bool publishing}) {
    if (faults.contains(SignalFault.electrodeDetached) ||
        faults.contains(SignalFault.poorContact)) {
      return publishing
          ? 'Press it back down before it stops reading.'
          : 'Press it back down. Nothing is being recorded until it reads.';
    }
    if (faults.contains(SignalFault.dropout)) {
      return 'Move closer to the device.';
    }
    if (faults.contains(SignalFault.sampleRateDrift)) {
      return null;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (level == SignalQualityLevel.good && !calibrationStalled) {
      return const SizedBox.shrink();
    }

    final k = context.kore;
    final text = Theme.of(context).textTheme;
    final line = headline(faults);
    if (line == null && !calibrationStalled) return const SizedBox.shrink();

    // Degraded still publishes; unusable does not. The difference changes what
    // the user is being asked to do, so it changes the sentence.
    final publishing = level != SignalQualityLevel.unusable;
    final detail = calibrationStalled
        ? 'Your baseline cannot be taken from a signal this noisy, so the '
            'countdown is waiting rather than running.'
        : action(faults, publishing: publishing);

    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: KoreSpace.md, vertical: KoreSpace.sm),
      decoration: BoxDecoration(
        color: k.surface,
        borderRadius: BorderRadius.circular(KoreRadius.md),
        border: Border.all(color: k.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            line ?? 'Waiting for a clean signal',
            style: text.titleSmall?.copyWith(color: k.unmeasured),
          ),
          if (detail != null) ...[
            const SizedBox(height: KoreSpace.xxs),
            Text(detail, style: text.bodySmall),
          ],
        ],
      ),
    );
  }
}
