import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/band_powers.dart';
import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/services/signal_quality.dart';

/// Feed [frames] frames at a fixed theta/alpha and quality, and return the
/// index afterwards.
double _drive(
  CognitiveLoadIndex cli,
  double theta,
  double alpha,
  int frames, {
  SignalQualityLevel quality = SignalQualityLevel.good,
}) {
  for (var i = 0; i < frames; i++) {
    cli.update(
      BandPowers(theta: theta, alpha: alpha, total: theta + alpha, frameIndex: i),
      quality: quality,
    );
  }
  return cli.value;
}

// A calm frame and a loaded one, in the same numbers the rest of the suite
// uses so the two files describe the same user.
const double _calmTheta = 71.0, _calmAlpha = 630.0;
const double _loadTheta = 493.0, _loadAlpha = 85.0;

void main() {
  group('the baseline', () {
    test('is never captured from a degraded signal', () {
      final cli = CognitiveLoadIndex();
      _drive(cli, _calmTheta, _calmAlpha, 200,
          quality: SignalQualityLevel.degraded);

      expect(cli.isCalibrated, isFalse,
          reason: 'a baseline off a slipping electrode poisons the session');
      expect(cli.calibrationProgress, 0);
      expect(cli.state, LoadState.calibrating);
    });

    test('is never captured from an unusable one either', () {
      final cli = CognitiveLoadIndex();
      _drive(cli, _calmTheta, _calmAlpha, 200,
          quality: SignalQualityLevel.unusable);
      expect(cli.isCalibrated, isFalse);
    });

    test('stalls through a bad patch rather than starting over', () {
      final cli = CognitiveLoadIndex();

      _drive(cli, _calmTheta, _calmAlpha, 30);
      final halfway = cli.calibrationProgress;
      expect(halfway, closeTo(0.5, 1e-9));

      _drive(cli, _loadTheta, _loadAlpha, 100,
          quality: SignalQualityLevel.unusable);
      expect(cli.calibrationProgress, closeTo(halfway, 1e-9),
          reason: 'frames it could not see must neither count nor discount');

      _drive(cli, _calmTheta, _calmAlpha, 30);
      expect(cli.isCalibrated, isTrue);
    });

    test('is the mean of the good frames only', () {
      final clean = CognitiveLoadIndex();
      _drive(clean, _calmTheta, _calmAlpha, 60);

      final interrupted = CognitiveLoadIndex();
      _drive(interrupted, _calmTheta, _calmAlpha, 30);
      _drive(interrupted, _loadTheta, _loadAlpha, 40,
          quality: SignalQualityLevel.unusable);
      _drive(interrupted, _calmTheta, _calmAlpha, 30);

      expect(interrupted.baseline, closeTo(clean.baseline, 1e-9),
          reason: 'the artifact must leave no trace in the reference');
    });
  });

  group('an unusable frame', () {
    test('freezes the index rather than publishing a new number', () {
      final cli = CognitiveLoadIndex();
      _drive(cli, _calmTheta, _calmAlpha, 60);
      final calm = _drive(cli, _calmTheta, _calmAlpha, 40);

      // The dangerous input: theta up, alpha down, from an electrode that has
      // come off rather than from a strained user.
      final held = _drive(cli, _loadTheta, _loadAlpha, 200,
          quality: SignalQualityLevel.unusable);

      expect(held, closeTo(calm, 1e-12),
          reason: 'the artifact must not move the number at all');
      expect(cli.isReadingTrustworthy, isFalse);
      expect(cli.state, isNot(LoadState.strain));
    });

    test('withdraws a strain claim instead of holding it', () {
      final cli = CognitiveLoadIndex();
      _drive(cli, _calmTheta, _calmAlpha, 60);
      _drive(cli, _loadTheta, _loadAlpha, 60);
      expect(cli.state, LoadState.strain);

      _drive(cli, _loadTheta, _loadAlpha, 1,
          quality: SignalQualityLevel.unusable);
      expect(cli.state, LoadState.steady,
          reason: 'strain asserts sustained load; one bad frame withdraws it');
      expect(cli.isReadingTrustworthy, isFalse);
    });

    test('makes strain re-earn its dwell once the signal is back', () {
      final cli = CognitiveLoadIndex();
      _drive(cli, _calmTheta, _calmAlpha, 60);
      _drive(cli, _loadTheta, _loadAlpha, 60);
      _drive(cli, _loadTheta, _loadAlpha, 4,
          quality: SignalQualityLevel.unusable);

      _drive(cli, _loadTheta, _loadAlpha, CognitiveLoadIndex.kStrainDwellFrames - 1);
      expect(cli.state, LoadState.steady);

      _drive(cli, _loadTheta, _loadAlpha, 1);
      expect(cli.state, LoadState.strain);
      expect(cli.isReadingTrustworthy, isTrue);
    });

    test('teaches the personal profile nothing', () {
      final cli = CognitiveLoadIndex();
      _drive(cli, _calmTheta, _calmAlpha, 60);
      _drive(cli, _calmTheta, _calmAlpha, 40);
      final frames = cli.profile.indexFrames;

      _drive(cli, _loadTheta, _loadAlpha, 300,
          quality: SignalQualityLevel.unusable);

      expect(cli.profile.indexFrames, frames,
          reason: 'a threshold learned from an artifact is wrong for life');
    });
  });

  test('a degraded frame still publishes a reading', () {
    final cli = CognitiveLoadIndex();
    _drive(cli, _calmTheta, _calmAlpha, 60);

    final loaded = _drive(cli, _loadTheta, _loadAlpha, 60,
        quality: SignalQualityLevel.degraded);
    expect(loaded, greaterThan(70.0));
    expect(cli.state, LoadState.strain,
        reason: 'a warning worth acting on is not withheld over a slipping band');
    expect(cli.isReadingTrustworthy, isTrue);
  });

  test('a caller with no quality information behaves exactly as before', () {
    final withOut = CognitiveLoadIndex();
    _drive(withOut, _calmTheta, _calmAlpha, 60);
    final a = _drive(withOut, _loadTheta, _loadAlpha, 60);

    final withGood = CognitiveLoadIndex();
    for (var i = 0; i < 120; i++) {
      final theta = i < 60 ? _calmTheta : _loadTheta;
      final alpha = i < 60 ? _calmAlpha : _loadAlpha;
      withGood.update(
        BandPowers(theta: theta, alpha: alpha, total: theta + alpha, frameIndex: i),
        quality: SignalQualityLevel.good,
      );
    }
    expect(withGood.value, closeTo(a, 1e-12));
  });
}
