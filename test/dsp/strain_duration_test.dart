import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/band_powers.dart';
import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/dsp/dsp_engine.dart';
import 'package:kore/services/signal_quality.dart';

/// Band powers whose log theta/alpha ratio is exactly [logRatio]. The same
/// helper the threshold tests use, so both files drive the index in the units
/// it actually works in.
BandPowers _atRatio(double logRatio, int frame) => BandPowers(
      theta: 100.0 * math.exp(logRatio),
      alpha: 100.0,
      total: 100.0 * math.exp(logRatio) + 100.0,
      frameIndex: frame,
    );

/// The deviation from baseline that puts the index at [target] - the inverse
/// of the logistic, so a test can say "drive it to 85".
double _deviationFor(double target) =>
    CognitiveLoadIndex.kOffset +
    CognitiveLoadIndex.kScale * math.log(target / (100 - target));

/// Feed [frames] frames at a fixed log ratio and quality.
void _drive(
  CognitiveLoadIndex cli,
  double logRatio,
  int frames, {
  SignalQualityLevel quality = SignalQualityLevel.good,
}) {
  for (var i = 0; i < frames; i++) {
    cli.update(_atRatio(logRatio, i), quality: quality);
  }
}

/// 15 s of baseline capture, which is what leaves calibration.
void _calibrate(CognitiveLoadIndex cli) {
  _drive(cli, 0.0, 60);
  expect(cli.isCalibrated, isTrue);
}

/// Feed frames until strain latches.
void _driveUntilStrain(CognitiveLoadIndex cli, double logRatio,
    {int limit = 500}) {
  for (var i = 0; i < limit; i++) {
    cli.update(_atRatio(logRatio, i));
    if (cli.state == LoadState.strain) return;
  }
  fail('strain never latched within $limit frames');
}

/// Feed frames until the index first reaches the enter threshold - the frame
/// the episode is counted from.
void _driveUntilAboveEnter(CognitiveLoadIndex cli, double logRatio,
    {int limit = 500}) {
  for (var i = 0; i < limit; i++) {
    cli.update(_atRatio(logRatio, i));
    if (cli.value >= cli.strainEnter) return;
  }
  fail('the index never reached the enter threshold within $limit frames');
}

/// The duration a whole number of analysis frames occupies at 4 Hz.
Duration _frames(int n) =>
    Duration(milliseconds: (n * 1000 / DspConfig.nominal.framesPerSecond).round());

const double _loaded = 85.0; // comfortably above the default enter of 70
const double _calm = 20.0;

void main() {
  group('the strain episode clock', () {
    test('reads nothing at all while the baseline is still being taken', () {
      final cli = CognitiveLoadIndex();
      _drive(cli, _deviationFor(_loaded), 40);

      expect(cli.state, LoadState.calibrating);
      expect(cli.strainFor, isNull,
          reason: 'there is no index yet, so there is nothing to have lasted');
    });

    test('reads nothing while the user is merely steady', () {
      final cli = CognitiveLoadIndex();
      _calibrate(cli);
      _drive(cli, _deviationFor(30), 60);

      expect(cli.state, LoadState.steady);
      expect(cli.strainFor, isNull);
    });

    test('is already a full dwell long at the instant strain latches', () {
      // The subtle one. The episode is counted from the first frame of the run
      // that latched, so the number the notification quotes is the time the
      // user was above their threshold - not the time since the latch, which
      // would under-report every episode by five seconds.
      final cli = CognitiveLoadIndex();
      _calibrate(cli);
      _driveUntilStrain(cli, _deviationFor(_loaded));

      expect(cli.state, LoadState.strain);
      expect(cli.strainFor, _frames(CognitiveLoadIndex.kNominalStrainDwellFrames));
      expect(cli.strainFor, const Duration(seconds: 5),
          reason: 'the dwell is part of the episode, not a delay before it');
    });

    test('advances one analysis frame per frame fed', () {
      final cli = CognitiveLoadIndex();
      _calibrate(cli);
      _driveUntilStrain(cli, _deviationFor(_loaded));

      _drive(cli, _deviationFor(_loaded), 4);
      expect(cli.strainFor,
          _frames(CognitiveLoadIndex.kNominalStrainDwellFrames + 4));
      expect(cli.strainFor, const Duration(seconds: 6));
    });

    test('keeps growing between exit and enter, because that band is '
        'hysteresis and not recovery', () {
      final cli = CognitiveLoadIndex();
      _calibrate(cli);
      _driveUntilStrain(cli, _deviationFor(_loaded));

      // 65 sits between the default exit of 60 and enter of 70.
      _drive(cli, _deviationFor(65), 40);

      expect(cli.state, LoadState.strain);
      expect(cli.value, greaterThan(cli.strainExit));
      expect(cli.value, lessThan(cli.strainEnter));
      expect(cli.strainFor,
          _frames(CognitiveLoadIndex.kNominalStrainDwellFrames + 40),
          reason: 'the episode did not pause while the index dipped inside '
              'its own hysteresis');
    });

    test('clears the moment the index falls below the exit threshold', () {
      final cli = CognitiveLoadIndex();
      _calibrate(cli);
      _driveUntilStrain(cli, _deviationFor(_loaded));
      expect(cli.strainFor, isNotNull);

      _drive(cli, _deviationFor(_calm), 80);

      expect(cli.state, LoadState.steady);
      expect(cli.strainFor, isNull,
          reason: 'a finished episode has no duration, it has a history entry');
    });

    test('discards a run that fell back below enter before it ever latched',
        () {
      final cli = CognitiveLoadIndex();
      _calibrate(cli);

      // One frame short of latching.
      _driveUntilAboveEnter(cli, _deviationFor(_loaded));
      _drive(cli, _deviationFor(_loaded),
          CognitiveLoadIndex.kNominalStrainDwellFrames - 2);
      expect(cli.state, LoadState.steady);
      expect(cli.strainFor, isNull);

      // Back down, then a real episode later on.
      _drive(cli, _deviationFor(_calm), 80);
      _driveUntilStrain(cli, _deviationFor(_loaded));

      expect(cli.strainFor, _frames(CognitiveLoadIndex.kNominalStrainDwellFrames),
          reason: 'the abandoned run must not be credited to the episode that '
              'actually happened');
    });

    test('is withdrawn outright by an unusable frame, not merely paused', () {
      final cli = CognitiveLoadIndex();
      _calibrate(cli);
      _driveUntilStrain(cli, _deviationFor(_loaded));
      _drive(cli, _deviationFor(_loaded), 60);
      expect(cli.strainFor, greaterThan(const Duration(seconds: 15)));

      _drive(cli, _deviationFor(_loaded), 1,
          quality: SignalQualityLevel.unusable);

      expect(cli.state, LoadState.steady);
      expect(cli.strainFor, isNull,
          reason: 'the claim and the clock are withdrawn together');
    });

    test('counts a resumed episode afresh rather than across the outage', () {
      // The property the doc comment argues for: the number may never span a
      // stretch nothing was measured. A wall-clock `strainSince` would have
      // reported the whole thing.
      final cli = CognitiveLoadIndex();
      _calibrate(cli);
      _driveUntilStrain(cli, _deviationFor(_loaded));
      _drive(cli, _deviationFor(_loaded), 200); // 50 s of real strain

      // Five minutes with the electrode off, at a ratio that looks loaded
      // precisely because it fell off.
      _drive(cli, _deviationFor(_loaded), 1200,
          quality: SignalQualityLevel.unusable);
      expect(cli.strainFor, isNull);

      _driveUntilStrain(cli, _deviationFor(_loaded));
      expect(cli.strainFor, _frames(CognitiveLoadIndex.kNominalStrainDwellFrames),
          reason: 'the episode is the measured five seconds, not the six '
              'minutes since it first latched');
    });

    test('does not survive a recalibrate', () {
      final cli = CognitiveLoadIndex();
      _calibrate(cli);
      _driveUntilStrain(cli, _deviationFor(_loaded));
      expect(cli.strainFor, isNotNull);

      cli.recalibrate();

      expect(cli.state, LoadState.calibrating);
      expect(cli.strainFor, isNull);
    });

    test('does not survive a reset either', () {
      final cli = CognitiveLoadIndex();
      _calibrate(cli);
      _driveUntilStrain(cli, _deviationFor(_loaded));

      cli.reset();

      expect(cli.strainFor, isNull);
      expect(cli.value, 0);
    });
  });
}
