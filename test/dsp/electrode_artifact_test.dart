import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/dsp/dsp_engine.dart';
import 'package:kore/services/signal_quality.dart';
import 'package:kore/sources/scenario_eeg_generator.dart';

/// Runs [seconds] of generator output through the real DSP chain at a fixed
/// [quality], and returns the mean index over the calibrated part of it.
double _run(
  ScenarioEEGGenerator gen,
  DartDspEngine engine,
  CognitiveLoadIndex cli,
  double seconds, {
  SignalQualityLevel quality = SignalQualityLevel.good,
}) {
  final blocks = (seconds * DspConfig.framesPerSecond).round();
  var sum = 0.0;
  var count = 0;

  for (var b = 0; b < blocks; b++) {
    engine.pushBlock(List<double>.generate(
        DspConfig.hopSize, (_) => gen.nextSampleMicrovolts()));
    final frame = engine.takeFrame();
    if (frame == null) continue;
    cli.update(frame, quality: quality);
    if (cli.isCalibrated) {
      sum += cli.value;
      count++;
    }
  }

  return count == 0 ? double.nan : sum / count;
}

void main() {
  test('the hazard: a detached electrode reads as strain', () {
    // This is the test the whole quality path exists because of. Nothing here
    // is wired to quality - it is the app as it was - and the point is that
    // the number it produces is not obviously wrong. It is plausible, it is
    // high, and there is nobody behind it.
    final gen = ScenarioEEGGenerator(seed: 11, tauSeconds: 0.5);
    final engine = DartDspEngine();
    final cli = CognitiveLoadIndex();

    gen.snapLoad(0.15);
    _run(gen, engine, cli, 25);
    expect(cli.isCalibrated, isTrue);
    final calm = _run(gen, engine, cli, 10);
    expect(calm, lessThan(45.0), reason: 'calm=$calm');

    // The user has not moved. The electrode has.
    gen.contact = 0.0;
    _run(gen, engine, cli, 15); // settle
    final detached = _run(gen, engine, cli, 15);

    expect(detached, greaterThan(70.0),
        reason: 'a floating electrode reads high: detached=$detached');
    expect(cli.state, LoadState.strain,
        reason: 'and the app would have offered a reset for it');
  });

  test('the same signal publishes nothing when quality is honoured', () {
    final gen = ScenarioEEGGenerator(seed: 11, tauSeconds: 0.5);
    final engine = DartDspEngine();
    final cli = CognitiveLoadIndex();

    gen.snapLoad(0.15);
    _run(gen, engine, cli, 25);
    final calm = _run(gen, engine, cli, 10);

    gen.contact = 0.0;
    _run(gen, engine, cli, 30, quality: SignalQualityLevel.unusable);

    expect(cli.value, closeTo(calm, 5.0),
        reason: 'the index is the last one measured, not the artifact');
    expect(cli.state, isNot(LoadState.strain));
    expect(cli.isReadingTrustworthy, isFalse);
  });

  test('a perfectly seated electrode changes nothing about the signal', () {
    // The identity that keeps every published figure reproducible: at contact
    // 1.0 the generator is what it was before an electrode was modelled.
    final withContact = ScenarioEEGGenerator(seed: 3);
    final untouched = ScenarioEEGGenerator(seed: 3);
    withContact.contact = 1.0;

    for (var n = 0; n < 4096; n++) {
      expect(withContact.nextSampleMicrovolts(),
          untouched.nextSampleMicrovolts());
    }
  });

  test('losing contact raises theta and drops alpha, which is the problem', () {
    final gen = ScenarioEEGGenerator(seed: 5);
    final engine = DartDspEngine();

    gen.snapLoad(0.15);
    void push(double seconds) {
      final blocks = (seconds * DspConfig.framesPerSecond).round();
      for (var b = 0; b < blocks; b++) {
        engine.pushBlock(List<double>.generate(
            DspConfig.hopSize, (_) => gen.nextSampleMicrovolts()));
        engine.takeFrame();
      }
    }

    push(8);
    engine.pushBlock(List<double>.generate(
        DspConfig.hopSize, (_) => gen.nextSampleMicrovolts()));
    final seated = engine.takeFrame()!;

    gen.contact = 0.0;
    push(8);
    engine.pushBlock(List<double>.generate(
        DspConfig.hopSize, (_) => gen.nextSampleMicrovolts()));
    final floating = engine.takeFrame()!;

    expect(floating.theta, greaterThan(seated.theta * 2),
        reason: 'motion and half-cell drift live under 7 Hz');
    expect(floating.alpha, lessThan(seated.alpha * 0.5),
        reason: 'the alpha it is no longer picking up goes with it');
  });
}
