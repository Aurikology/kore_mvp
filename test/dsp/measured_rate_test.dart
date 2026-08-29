import 'dart:math' as math;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/band_powers.dart';
import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/dsp/dsp_engine.dart';
import 'package:kore/dsp/focus_crash_predictor.dart';
import 'package:kore/services/signal_quality.dart';
import 'package:kore/session/kore_session.dart';
import 'package:kore/sources/simulated_eeg_source.dart';

/// A crystal 2% fast: 261.12 Hz, the same figure the simulator's drift lever
/// produces, and well inside what a cheap oscillator can do.
const double _fastCrystalHz = 256.0 * 1.02;

void _advance(FakeAsync async, Duration d) {
  async.elapse(d);
  async.flushMicrotasks();
}

/// RMS of the engine's output over [seconds] of a pure sine at [toneHz],
/// sampled at [sampledAtHz] - i.e. the sequence the device actually hands
/// over - after discarding the filter's settling transient.
double _residualRms(
  DspEngine engine, {
  required double toneHz,
  required double sampledAtHz,
  double seconds = 4.0,
}) {
  final total = (seconds * sampledAtHz).round();
  final settle = sampledAtHz.round(); // one second
  var sumSq = 0.0;
  var counted = 0;

  for (var n = 0; n < total; n++) {
    engine.pushBlock([math.sin(2 * math.pi * toneHz * n / sampledAtHz)]);
    if (n >= settle) {
      final y = engine.lastFiltered;
      sumSq += y * y;
      counted++;
    }
  }
  return math.sqrt(sumSq / counted);
}

void main() {
  group('DspConfig carries a rate', () {
    test('the nominal configuration reproduces every published frame count',
        () {
      const c = DspConfig.nominal;
      expect(c.sampleRateHz, 256.0);
      expect(c.framesPerSecond, 4.0);
      expect(c.windowSeconds, 2.0);
      expect(c.binWidthHz, 0.5);
      expect(c.isOffNominal, isFalse);

      expect(c.framesForSeconds(CognitiveLoadIndex.kCalibrationSeconds), 60);
      expect(c.framesForSeconds(CognitiveLoadIndex.kStrainDwellSeconds), 20);
      expect(c.framesForSeconds(FocusCrashPredictor.kWindowSeconds), 48);
      expect(c.framesForSeconds(FocusCrashPredictor.kMinWindowSeconds), 24);
      expect(c.framesForSeconds(FocusCrashPredictor.kConfirmSeconds), 4);
    });

    test('a faster crystal frames faster, and the counts follow', () {
      const c = DspConfig(sampleRateHz: _fastCrystalHz);
      expect(c.isOffNominal, isTrue);
      expect(c.framesPerSecond, closeTo(4.08, 1e-9));
      expect(c.windowSeconds, closeTo(1.9608, 1e-4));

      // 12 s of trajectory is 49 frames on this device, not 48. One frame is
      // not much; the point is that it is the number of frames that actually
      // spans twelve seconds here.
      expect(c.framesForSeconds(FocusCrashPredictor.kWindowSeconds), 49);
      expect(c.framesToDuration(49).inMilliseconds, closeTo(12010, 5));
    });

    test('a rate that cannot be believed falls back to nominal', () {
      for (final bogus in [0.0, -256.0, double.nan, double.infinity, 8000.0]) {
        expect(DspConfig.forMeasuredRate(bogus).sampleRateHz,
            DspConfig.nominalSampleRateHz,
            reason: '$bogus is not a crystal');
      }
    });

    test('a plausible measured rate is taken as given', () {
      expect(DspConfig.forMeasuredRate(255.7).sampleRateHz, 255.7);
      expect(DspConfig.forMeasuredRate(_fastCrystalHz).sampleRateHz,
          _fastCrystalHz);
    });

    test('a duration never rounds away to nothing', () {
      // A dwell of one frame is still a dwell; a dwell of zero frames is a
      // latch with no dwell at all, which is a different feature.
      expect(const DspConfig(sampleRateHz: 240).framesForSeconds(0.001), 1);
    });
  });

  group('the notch follows the crystal', () {
    test('mains is rejected far harder when the engine knows the real rate',
        () {
      // The device samples at 261.12 Hz. Mains is 60.000 Hz in the world
      // regardless, so this is the sequence it actually delivers.
      final tuned =
          DartDspEngine(config: DspConfig.forMeasuredRate(_fastCrystalHz));
      final mistuned = DartDspEngine(config: DspConfig.nominal);

      final tunedRms = _residualRms(tuned,
          toneHz: DspConfig.mainsHz, sampledAtHz: _fastCrystalHz);
      final mistunedRms = _residualRms(mistuned,
          toneHz: DspConfig.mainsHz, sampledAtHz: _fastCrystalHz);

      // Built against 256 Hz, the notch sits at 61.2 Hz in real terms - 1.2 Hz
      // off a notch whose bandwidth is only 3 Hz, so most of the mains walks
      // straight through it. Measured on a unit-amplitude tone: 0.00019
      // residual tuned, 0.53920 mistuned. Over half the mains survives a
      // filter whose entire job is removing it.
      expect(tunedRms, lessThan(0.001));
      expect(mistunedRms, greaterThan(0.4));
      expect(tunedRms, lessThan(mistunedRms / 100),
          reason: 'tuned $tunedRms vs mistuned $mistunedRms');
    });

    test('even a cheap crystal is enough to open the notch', () {
      // 0.5% is unremarkable for an uncompensated oscillator, and it is
      // already a fifth of the mains getting through. This is the argument for
      // tuning to the measured rate rather than banding the error as a fault
      // and hoping it stays small.
      const nearlyRightHz = 256.0 * 1.005;
      final mistuned = DartDspEngine(config: DspConfig.nominal);
      final rms = _residualRms(mistuned,
          toneHz: DspConfig.mainsHz, sampledAtHz: nearlyRightHz);
      expect(rms, greaterThan(0.15));
    });

    test('at the nominal rate the two are the same filter', () {
      final tuned = DartDspEngine(config: DspConfig.forMeasuredRate(256.0));
      final nominal = DartDspEngine();
      expect(
        _residualRms(tuned,
            toneHz: DspConfig.mainsHz, sampledAtHz: 256.0),
        _residualRms(nominal,
            toneHz: DspConfig.mainsHz, sampledAtHz: 256.0),
      );
    });

    test('the tuned engine is no worse in the passband', () {
      // The correction must not be bought by attenuating signal: 10 Hz alpha
      // passes essentially untouched.
      final tuned =
          DartDspEngine(config: DspConfig.forMeasuredRate(_fastCrystalHz));
      final rms =
          _residualRms(tuned, toneHz: 10.0, sampledAtHz: _fastCrystalHz);
      expect(rms, closeTo(math.sqrt(0.5), 0.05));
    });
  });

  group('the index and the predictor count in real seconds', () {
    test('the nominal index is unchanged, to the coefficient', () {
      final cli = CognitiveLoadIndex();
      expect(cli.config.sampleRateHz, DspConfig.nominalSampleRateHz);
      expect(
          cli.strainDwellFrames, CognitiveLoadIndex.kNominalStrainDwellFrames);
      expect(cli.strainDwellFrames, 20);
      // Exactly, not approximately: every published figure is quoted against
      // this number, and a pow() returning 0.11999999999999999 would be a
      // different app.
      expect(cli.emaAlpha, CognitiveLoadIndex.kEmaAlpha);
    });

    test('a faster crystal dwells for the same five seconds', () {
      final cli = CognitiveLoadIndex(
          config: const DspConfig(sampleRateHz: _fastCrystalHz));
      expect(cli.strainDwellFrames, 20,
          reason: '5 s at 4.08 Hz is 20.4 frames, which rounds to 20');
      expect(cli.config.framesToDuration(cli.strainDwellFrames).inMilliseconds,
          closeTo(4902, 5));
    });

    test('the EMA keeps its time constant rather than its coefficient', () {
      const fast = DspConfig(sampleRateHz: _fastCrystalHz);
      final cli = CognitiveLoadIndex(config: fast);

      // tau = -1 / (fps * ln(1 - alpha)), and tau is what was tuned to 2.1 s.
      // A faster frame rate has to take smaller steps to hold it.
      double tau(double alpha, double fps) =>
          -1.0 / (fps * math.log(1.0 - alpha));

      expect(cli.emaAlpha, lessThan(CognitiveLoadIndex.kEmaAlpha));
      expect(
        tau(cli.emaAlpha, fast.framesPerSecond),
        closeTo(
            tau(CognitiveLoadIndex.kEmaAlpha,
                DspConfig.nominal.framesPerSecond),
            1e-9),
      );
    });

    test('a faster crystal smooths over the same real time, not frames', () {
      // The smoothing as *applied*, not the getter's arithmetic. A crystal 8%
      // fast, so the correction is bigger than one frame of quantisation and
      // the test can actually tell the two apart.
      const fast = DspConfig(sampleRateHz: 256.0 * 1.08);

      CognitiveLoadIndex calibrated(DspConfig config) {
        final cli = CognitiveLoadIndex(config: config);
        for (var i = 0; i < config.framesForSeconds(20); i++) {
          cli.update(const BandPowers(
              theta: 100, alpha: 100, total: 200, frameIndex: 0));
        }
        expect(cli.isCalibrated, isTrue);
        return cli;
      }

      const step =
          BandPowers(theta: 900, alpha: 100, total: 1000, frameIndex: 0);

      // Where the nominal index has got to six seconds into the step.
      final ref = calibrated(DspConfig.nominal);
      for (var i = 0; i < DspConfig.nominal.framesForSeconds(6); i++) {
        ref.update(step);
      }
      final target = ref.value;

      // How long the fast device takes to reach the same place, in seconds.
      final cli = calibrated(fast);
      var frames = 0;
      while (cli.value < target && frames < fast.framesForSeconds(30)) {
        cli.update(step);
        frames++;
      }
      final seconds = fast.framesToDuration(frames).inMilliseconds / 1000.0;

      // Six seconds, because the time constant is what was tuned. Applying the
      // raw 0.12 per frame here would get there in 6 / 1.08 = 5.6 s - the same
      // number of frames, less real time.
      expect(seconds, closeTo(6.0, 0.3),
          reason: 'reached the nominal 6 s value after $seconds s');
    });

    test('the predictor reports slope per real second, not per nominal frame',
        () {
      // The load-bearing one. `_frameSeconds` scales every slope the predictor
      // publishes and every `secondsToCrossing` derived from it, so reverting
      // it to the nominal rate silently rescales the whole forecast by the
      // crystal's error. 8% fast, so the error is far larger than the fit
      // noise.
      const fast = DspConfig(sampleRateHz: 256.0 * 1.08);
      final p = FocusCrashPredictor(config: fast);

      // A ramp climbing exactly 2.0 index points per *real* second.
      const climbPerSecond = 2.0;
      final frames = fast.framesForSeconds(12);
      var lastIndex = 0.0;
      for (var i = 0; i < frames; i++) {
        final t = i / fast.framesPerSecond;
        lastIndex = 40.0 + climbPerSecond * t;
        p.observe(
          index: lastIndex,
          deviation: lastIndex / 25.0,
          state: LoadState.steady,
          enterThreshold: 70.0,
        );
      }

      final f = p.forecast;
      expect(f.indexSlopePerSecond, closeTo(climbPerSecond, 0.02),
          reason: 'a predictor counting nominal frames would report '
              '${climbPerSecond / 1.08} here');

      // And the crossing that falls out of it, in real seconds: the distance
      // left to the threshold divided by that same real-time slope. Derived
      // from the last index rather than asserted as a constant, because the
      // last frame lands at 11.81 s on this crystal, not at 12.
      expect(f.secondsToCrossing, isNotNull);
      expect(f.secondsToCrossing!,
          closeTo((70.0 - lastIndex) / climbPerSecond, 0.05));
    });

    test('the predictor fits its line over twelve real seconds', () {
      final nominal = FocusCrashPredictor();
      final fast = FocusCrashPredictor(
          config: const DspConfig(sampleRateHz: _fastCrystalHz));
      expect(nominal.confirmFrames, FocusCrashPredictor.kNominalConfirmFrames);
      expect(fast.confirmFrames, 4, reason: '1 s at 4.08 Hz rounds to 4');
      expect(fast.config.framesToDuration(fast.confirmFrames).inMilliseconds,
          closeTo(980, 5));
    });
  });

  group('a session on a drifted crystal', () {
    KoreSession sessionAt(FakeAsync async, double rateErrorFraction) {
      final source = SimulatedEegSource(
        elapsedMicros: () => async.elapsed.inMicroseconds,
      );
      source.setSampleRateError(rateErrorFraction);
      return KoreSession(source: source);
    }

    test('tunes the whole analysis to what the device is actually doing', () {
      fakeAsync((async) {
        final session = sessionAt(async, 0.02);
        expect(session.tunedSampleRateHz, closeTo(_fastCrystalHz, 1e-9));
        expect(session.engine.config.sampleRateHz, session.tunedSampleRateHz);
        expect(session.index.config.sampleRateHz, session.tunedSampleRateHz);
        expect(
            session.predictor.config.sampleRateHz, session.tunedSampleRateHz);
        expect(
            session.signalGate.config.sampleRateHz, session.tunedSampleRateHz);
        session.dispose();
      });
    });

    test('calibrates and reads instead of being suppressed forever', () {
      fakeAsync((async) {
        final session = sessionAt(async, 0.02);
        session.start();
        async.flushMicrotasks();
        _advance(async, const Duration(seconds: 25));

        // This is the whole point of the change. Before it, the source's 2%
        // reported drift was measured against a 256 Hz constant, banded as a
        // fault, and the gate refused every frame - so a perfectly good device
        // with a slightly fast crystal could never finish calibrating.
        expect(session.isCalibrated, isTrue);
        expect(session.signalQualityLevel, SignalQualityLevel.good);
        expect(session.signalFaults, isEmpty);
        expect(session.isReadingTrustworthy, isTrue);
        session.dispose();
      });
    });

    test('the source still reports the drift it measured', () {
      fakeAsync((async) {
        final session = sessionAt(async, 0.02);
        session.start();
        async.flushMicrotasks();
        _advance(async, const Duration(seconds: 5));

        // Accommodating a rate is not the same as pretending it is 256 Hz.
        // The measurement stands and stays visible; only the verdict on it
        // changes, because the analysis moved to meet it.
        expect(session.measuredSampleRateHz, closeTo(_fastCrystalHz, 1e-9));
        expect(session.source.quality.faults, {SignalFault.sampleRateDrift},
            reason: 'the source compares against its own nominal, as it must');
        expect(session.signalFaults, isEmpty,
            reason: 'the gate compares against what the engine was built for');
        session.dispose();
      });
    });

    test('a crystal that moves away from the tuning is still a fault', () {
      fakeAsync((async) {
        final session = sessionAt(async, 0.02);
        session.start();
        async.flushMicrotasks();
        _advance(async, const Duration(seconds: 25));
        expect(session.signalFaults, isEmpty);

        // The engine was tuned at 261.12 Hz and the crystal has now moved on
        // to 266.24. That is a real detuning, and exactly what the drift
        // banding exists for.
        (session.source as SimulatedEegSource).setSampleRateError(0.04);
        _advance(async, const Duration(seconds: 3));

        expect(session.signalFaults, contains(SignalFault.sampleRateDrift));
        expect(session.signalQualityLevel, isNot(SignalQualityLevel.good));
        session.dispose();
      });
    });
  });
}
