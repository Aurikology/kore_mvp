import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/dsp/dsp_engine.dart';
import 'package:kore/dsp/focus_crash_predictor.dart';
import 'package:kore/sources/scenario_eeg_generator.dart';

final _fps = DspConfig.nominal.framesPerSecond;

/// Feed [frames] synthetic frames, with [index] and [deviation] given as
/// functions of elapsed seconds so the trajectories below read as the shapes
/// they are rather than as loop arithmetic.
void _drive(
  FocusCrashPredictor p, {
  required int frames,
  required double Function(double t) index,
  double Function(double t)? deviation,
  LoadState state = LoadState.steady,
  double enter = CognitiveLoadIndex.kStrainEnter,
  double startSeconds = 0,
  void Function(double t)? onEach,
}) {
  for (var i = 0; i < frames; i++) {
    final t = startSeconds + i / _fps;
    final v = index(t);
    p.observe(
      index: v,
      // The default keeps the ratio moving with the index, which is the
      // physiological case: the index is a monotone function of the deviation.
      deviation: deviation?.call(t) ?? v / 25.0,
      state: state,
      enterThreshold: enter,
    );
    onEach?.call(t);
  }
}

void main() {
  group('honesty about what it cannot know', () {
    test('says nothing at all before calibration completes', () {
      final p = FocusCrashPredictor();

      // A textbook crash trajectory - but with no baseline the index it would
      // be extrapolating is not defined against anything.
      _drive(p,
          frames: 120,
          state: LoadState.calibrating,
          index: (t) => 20.0 + 3.0 * t);

      expect(p.forecast.status, CrashForecastStatus.uncalibrated);
      expect(p.forecast.isWarning, isFalse);
      expect(p.forecast.confidence, 0);
      expect(p.forecast.secondsToCrossing, isNull);
    });

    test('warms up before it will fit a line to anything', () {
      final p = FocusCrashPredictor();

      _drive(p, frames: 8, index: (t) => 40.0 + 2.0 * t); // 2 s
      expect(p.forecast.status, CrashForecastStatus.warmingUp);
      expect(p.forecast.confidence, 0);

      _drive(p,
          frames: 24, startSeconds: 2.0, index: (t) => 40.0 + 2.0 * t); // 8 s
      expect(p.forecast.status, isNot(CrashForecastStatus.warmingUp),
          reason: 'six seconds of trajectory is enough to fit');
    });

    test('forecasts nothing once strain has already latched', () {
      final p = FocusCrashPredictor();

      _drive(p, frames: 80, index: (t) => 40.0 + 1.0 * t);
      _drive(p,
          frames: 40,
          startSeconds: 20,
          state: LoadState.strain,
          index: (t) => 40.0 + 1.0 * t);

      expect(p.forecast.status, CrashForecastStatus.alreadyStrained);
      expect(p.forecast.isWarning, isFalse,
          reason: 'the app should be offering a reset, not predicting one');
    });

    test('calibrating again discards the trajectory behind it', () {
      final p = FocusCrashPredictor();

      _drive(p, frames: 80, index: (t) => 40.0 + 1.5 * t);
      expect(p.forecast.isWarning, isTrue);

      // The baseline moved, so every index value before it means something
      // different. A window spanning that moment would fit a line to a step.
      _drive(p, frames: 1, state: LoadState.calibrating, index: (_) => 60);
      expect(p.forecast.status, CrashForecastStatus.uncalibrated);

      _drive(p, frames: 8, index: (t) => 60.0 + 1.5 * t);
      expect(p.forecast.status, CrashForecastStatus.warmingUp);
    });

    test('reset returns it to silence', () {
      final p = FocusCrashPredictor();
      _drive(p, frames: 80, index: (t) => 40.0 + 1.5 * t);
      expect(p.forecast.isWarning, isTrue);

      p.reset();
      expect(p.forecast.status, CrashForecastStatus.uncalibrated);
      expect(p.forecast.confidence, 0);
    });
  });

  group('trajectories that must predict nothing', () {
    test('a flat index predicts nothing', () {
      final p = FocusCrashPredictor();
      _drive(p, frames: 200, index: (_) => 40.0);

      expect(p.forecast.status, CrashForecastStatus.steady);
      expect(p.forecast.secondsToCrossing, isNull,
          reason: 'a flat line never reaches the threshold');
      expect(p.forecast.indexSlopePerSecond, closeTo(0, 1e-9));
    });

    test('a falling index predicts nothing', () {
      final p = FocusCrashPredictor();
      _drive(p, frames: 200, index: (t) => 65.0 - 0.5 * t);

      expect(p.forecast.status, CrashForecastStatus.steady);
      expect(p.forecast.isWarning, isFalse);
      expect(p.forecast.indexSlopePerSecond, lessThan(0));
    });

    test('a climb too slow to arrive inside the horizon predicts nothing', () {
      final p = FocusCrashPredictor();
      _drive(p, frames: 200, index: (t) => 40.0 + 0.15 * t);

      expect(p.forecast.status, CrashForecastStatus.steady);
      expect(p.forecast.secondsToCrossing,
          greaterThan(FocusCrashPredictor.kHorizonSeconds),
          reason: 'the crossing is real but far away, and saying so is the '
              'more useful answer than saying nothing');
    });

    test('a rise the theta/alpha ratio contradicts is not a warning', () {
      final p = FocusCrashPredictor();

      // The EMA case: the index is still coasting upward while the driver
      // behind it has already turned over. This is precisely the shape that a
      // naive extrapolation of the smoothed index warns on.
      _drive(p,
          frames: 200,
          index: (t) => 40.0 + 1.5 * t,
          deviation: (t) => 2.0 - 0.08 * t);

      expect(p.forecast.status, CrashForecastStatus.steady);
      expect(p.forecast.indexSlopePerSecond, greaterThan(1.0),
          reason: 'the index really is climbing - the veto is the ratio');
      expect(p.forecast.ratioSlopePerSecond, lessThan(0));
    });

    test('noise just under the threshold does not raise an alarm', () {
      final p = FocusCrashPredictor();
      final rng = math.Random(11);

      // Mean 62, +/- 8: individual windows will fit slopes steep enough to
      // reach 70 inside the horizon. What stops them is R^2 - a line through
      // noise explains almost none of it, and the confidence gate is where
      // that gets spent.
      var everWarned = false;
      _drive(p,
          frames: 400,
          index: (_) => 62.0 + 16.0 * (rng.nextDouble() - 0.5),
          // Held flat so the veto cannot be the reason it stays quiet.
          deviation: (_) => 1.4,
          onEach: (_) => everWarned |= p.forecast.isWarning);

      expect(everWarned, isFalse);
      expect(p.forecast.fit, lessThan(0.35),
          reason: 'the fit should be reporting how badly a line describes this');
    });
  });

  group('trajectories that must predict a crash', () {
    test('a steady climb warns well before the index arrives', () {
      final p = FocusCrashPredictor();

      double? warnedAt;
      double? indexAtWarning;
      _drive(p,
          frames: 160,
          index: (t) => 40.0 + 1.0 * t,
          onEach: (t) {
            if (warnedAt == null && p.forecast.isWarning) {
              warnedAt = t;
              indexAtWarning = 40.0 + 1.0 * t;
            }
          });

      expect(warnedAt, isNotNull, reason: 'a 1 point/s climb is a crash');
      // The index reaches 70 at t = 30 s.
      expect(warnedAt!, lessThan(30.0 - 15.0),
          reason: 'a warning with under 15 s of notice is not worth having');
      expect(indexAtWarning!, lessThan(CognitiveLoadIndex.kStrainEnter));
    });

    test('it names roughly the right time to the crossing', () {
      final p = FocusCrashPredictor();
      // Reaches 70 at t = 20 s; stop at t = 14 s, so 6 s remain.
      _drive(p, frames: 57, index: (t) => 40.0 + 1.5 * t);

      expect(p.forecast.isWarning, isTrue);
      expect(p.forecast.secondsToCrossing, closeTo(6.0, 0.5));
      expect(p.forecast.confidence, greaterThan(0.6));
      expect(p.forecast.fit, closeTo(1.0, 1e-6));
    });

    test('a single qualifying window is not enough to fire', () {
      final p = FocusCrashPredictor();

      int? firstQualifying;
      int? firstWarning;
      var frame = 0;
      _drive(p,
          frames: 200,
          index: (t) => 40.0 + 1.0 * t,
          onEach: (_) {
            final f = p.forecast;
            final qualifies = f.confidence >= FocusCrashPredictor.kMinConfidence;
            if (qualifies && firstQualifying == null) firstQualifying = frame;
            if (f.isWarning && firstWarning == null) firstWarning = frame;
            frame++;
          });

      expect(firstQualifying, isNotNull);
      expect(firstWarning, isNotNull);
      expect(firstWarning! - firstQualifying!,
          FocusCrashPredictor.kNominalConfirmFrames - 1,
          reason: 'the criteria must hold for the dwell before it publishes');
    });

    test('a personalised threshold is forecast against, not the default', () {
      // A user whose strain threshold sits at 85 must not be warned on the
      // trajectory that would cross 70.
      final low = FocusCrashPredictor();
      _drive(low, frames: 60, index: (t) => 45.0 + 1.0 * t);
      expect(low.forecast.isWarning, isTrue);

      final high = FocusCrashPredictor();
      _drive(high, frames: 60, index: (t) => 45.0 + 1.0 * t, enter: 85.0);
      expect(high.forecast.isWarning, isFalse);
      expect(high.forecast.secondsToCrossing,
          greaterThan(FocusCrashPredictor.kHorizonSeconds));
    });
  });

  test('warns ahead of the real pipeline latching into strain', () {
    // The claim the product makes, end to end: synthetic EEG -> filters ->
    // Goertzel -> index -> forecast, with nothing mocked but the electrode.
    final gen = ScenarioEEGGenerator(seed: 3, tauSeconds: 4.0);
    final engine = DartDspEngine();
    final cli = CognitiveLoadIndex();
    final predictor = FocusCrashPredictor();

    double? warnedAtSeconds;
    double? strainedAtSeconds;

    gen.snapLoad(0.15);
    final totalFrames = (90 * _fps).round();

    for (var f = 0; f < totalFrames; f++) {
      final seconds = f / _fps;

      // Calm through calibration, then a 30 s ramp into heavy load - the
      // scripted arc the demo runs.
      gen.loadTarget = seconds < 25
          ? 0.15
          : (0.15 + 0.75 * ((seconds - 25) / 30)).clamp(0.15, 0.90);

      engine.pushBlock(List<double>.generate(
          DspConfig.hopSize, (_) => gen.nextSampleMicrovolts()));
      final frame = engine.takeFrame();
      if (frame == null) continue;

      cli.update(frame);
      predictor.observe(
        index: cli.value,
        deviation: cli.deviation,
        state: cli.state,
      );

      if (warnedAtSeconds == null && predictor.forecast.isWarning) {
        warnedAtSeconds = seconds;
      }
      if (strainedAtSeconds == null && cli.state == LoadState.strain) {
        strainedAtSeconds = seconds;
      }
    }

    expect(strainedAtSeconds, isNotNull,
        reason: 'the ramp should have driven the index into strain');
    expect(warnedAtSeconds, isNotNull,
        reason: 'a 30 s ramp into strain is exactly the crash to predict');
    expect(warnedAtSeconds!, lessThan(strainedAtSeconds!),
        reason: 'warned=$warnedAtSeconds strained=$strainedAtSeconds');
    expect(strainedAtSeconds - warnedAtSeconds, greaterThan(5.0),
        reason: 'the lead has to be long enough to act on: '
            'warned=$warnedAtSeconds strained=$strainedAtSeconds');
  });
}
