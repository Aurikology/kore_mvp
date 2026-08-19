import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/band_powers.dart';
import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/dsp/load_profile.dart';

/// Band powers whose log theta/alpha ratio is exactly [logRatio]. Alpha is
/// pinned so the tests below can be written in the units the index actually
/// works in rather than in microvolts squared.
BandPowers _atRatio(double logRatio, int frame) => BandPowers(
      theta: 100.0 * math.exp(logRatio),
      alpha: 100.0,
      total: 100.0 * math.exp(logRatio) + 100.0,
      frameIndex: frame,
    );

/// The deviation from baseline that puts the index at [target].
///
/// The inverse of the logistic, so a test can say "drive it to 78" instead of
/// hand-tuning band powers until it lands there.
double _deviationFor(double target) =>
    CognitiveLoadIndex.kOffset +
    CognitiveLoadIndex.kScale * math.log(target / (100 - target));

/// Feed [frames] frames at a fixed log ratio and return the index afterwards.
double _drive(CognitiveLoadIndex cli, double logRatio, int frames) {
  for (var i = 0; i < frames; i++) {
    cli.update(_atRatio(logRatio, i));
  }
  return cli.value;
}

/// 15 s of baseline capture at [logRatio], which is what leaves calibration.
void _calibrate(CognitiveLoadIndex cli, {double logRatio = 0.0}) {
  _drive(cli, logRatio, 60);
  expect(cli.isCalibrated, isTrue);
}

/// A user with enough history on record to be personalised.
LoadProfile _establishedUser({
  required double meanIndex,
  required double sdIndex,
  double? baselineLogRatio,
}) =>
    LoadProfile(
      baselineLogRatio: baselineLogRatio,
      indexMean: meanIndex,
      indexVariance: sdIndex * sdIndex,
      indexFrames: LoadProfile.kMaxIndexFrames,
      sessionCount: 20,
    );

void main() {
  group('cold start', () {
    test('a fresh user gets exactly the published thresholds', () {
      final cli = CognitiveLoadIndex();

      expect(cli.strainEnter, CognitiveLoadIndex.kStrainEnter);
      expect(cli.strainExit, CognitiveLoadIndex.kStrainExit);
      expect(cli.isPersonalised, isFalse);

      // The documented calm and loaded readings, unchanged.
      _drive(cli, math.log(71.0 / 630.0), 60);
      expect(_drive(cli, math.log(71.0 / 630.0), 40),
          inInclusiveRange(20.0, 35.0));
      expect(_drive(cli, math.log(493.0 / 85.0), 60), greaterThan(70.0));
      expect(cli.state, LoadState.strain);

      expect(cli.strainEnter, CognitiveLoadIndex.kStrainEnter,
          reason: 'one short session is not a personal distribution');
    });

    test('a short first session personalises nothing', () {
      final cli = CognitiveLoadIndex();
      _calibrate(cli);
      _drive(cli, _deviationFor(90), 500); // just over two minutes

      expect(cli.profile.indexFrames, 500);
      expect(cli.isPersonalised, isFalse);
      expect(cli.strainEnter, CognitiveLoadIndex.kStrainEnter);
    });

    test('nothing accumulates into the profile before calibration lands', () {
      final cli = CognitiveLoadIndex();
      _drive(cli, 2.0, 40); // still capturing the baseline

      expect(cli.isCalibrated, isFalse);
      expect(cli.profile.indexFrames, 0,
          reason: 'there is no index yet to have a distribution');
      expect(cli.profile.sessionCount, 0);
    });
  });

  group('personal thresholds', () {
    test('a user who runs high is not left permanently in strain', () {
      final profile = _establishedUser(meanIndex: 78, sdIndex: 5);

      final personal = CognitiveLoadIndex(profile: profile);
      expect(personal.strainEnter, closeTo(83.0, 1e-9));
      expect(personal.strainExit, closeTo(73.0, 1e-9));
      expect(personal.isPersonalised, isTrue);

      // The identical signal, driven through both.
      final fresh = CognitiveLoadIndex();
      for (final cli in [personal, fresh]) {
        _calibrate(cli);
        _drive(cli, _deviationFor(78), 40);
      }

      expect(fresh.state, LoadState.strain,
          reason: 'the default thresholds call 78 strain, and for most '
              'people they are right');
      expect(personal.state, LoadState.steady,
          reason: '78 is this user\'s ordinary working load');
      expect(personal.value, closeTo(78.0, 0.5),
          reason: 'the index itself is unchanged - only the threshold moved');
    });

    test('the enter/exit gap is preserved, so the latch cannot flicker', () {
      final profiles = [
        LoadProfile.fresh,
        _establishedUser(meanIndex: 78, sdIndex: 5),
        _establishedUser(meanIndex: 95, sdIndex: 20),
        _establishedUser(meanIndex: 10, sdIndex: 1),
        _establishedUser(meanIndex: 45, sdIndex: 12),
      ];

      for (final p in profiles) {
        final cli = CognitiveLoadIndex(profile: p);
        expect(cli.strainEnter - cli.strainExit,
            closeTo(CognitiveLoadIndex.kThresholdGap, 1e-9),
            reason: 'profile: $p');
      }
    });

    test('personalisation is bounded at both ends', () {
      final high = CognitiveLoadIndex(
          profile: _establishedUser(meanIndex: 95, sdIndex: 20));
      expect(high.strainEnter, CognitiveLoadIndex.kEnterCeiling,
          reason: 'a threshold of 115 is not a threshold');

      final low = CognitiveLoadIndex(
          profile: _establishedUser(meanIndex: 10, sdIndex: 1));
      expect(low.strainEnter, CognitiveLoadIndex.kEnterFloor,
          reason: 'nor is a threshold of 11');
      expect(low.strainExit,
          CognitiveLoadIndex.kEnterFloor - CognitiveLoadIndex.kThresholdGap);
    });

    test('a personalised threshold latches with the same hysteresis', () {
      final cli = CognitiveLoadIndex(
          profile: _establishedUser(meanIndex: 78, sdIndex: 5));
      _calibrate(cli);

      _drive(cli, _deviationFor(85), 60); // above the personal enter of 83
      expect(cli.state, LoadState.strain);

      _drive(cli, _deviationFor(78), 60); // between exit and enter
      expect(cli.state, LoadState.strain,
          reason: 'dropping below enter must not clear strain - that is the '
              'whole point of two thresholds');

      _drive(cli, _deviationFor(70), 60); // below the personal exit of 73
      expect(cli.state, LoadState.steady);
    });
  });

  group('personal baseline', () {
    test('a session baseline is recorded for the next run to use', () {
      final cli = CognitiveLoadIndex();
      _calibrate(cli, logRatio: -1.4);

      expect(cli.baseline, closeTo(-1.4, 1e-9));
      expect(cli.profile.baselineLogRatio, closeTo(-1.4, 1e-9),
          reason: 'the first session defines the personal baseline outright');
      expect(cli.profile.sessionCount, 1);
    });

    test('a baseline captured mid-strain cannot redefine strain as normal', () {
      // The failure this exists to prevent: the user opens the app while
      // already loaded, the 15 s capture takes their strained ratio as
      // "normal", and the app reads steady for the rest of the hour.
      final known = CognitiveLoadIndex(
          profile: const LoadProfile(baselineLogRatio: 0.0, sessionCount: 6));
      final blank = CognitiveLoadIndex();

      for (final cli in [known, blank]) {
        _calibrate(cli, logRatio: 3.0); // calibrating during strain
        _drive(cli, 3.0, 20);
      }

      expect(known.baseline, closeTo(CognitiveLoadIndex.kBaselineTrustBand, 1e-9),
          reason: 'the capture is pulled back to the edge of the trust band, '
              'not rejected - a user with no baseline at all is worse');
      expect(known.value, greaterThan(50.0),
          reason: 'the app should be telling this user they are loaded');
      expect(blank.value, lessThan(30.0));
      expect(known.value - blank.value, greaterThan(25.0));
    });

    test('the long-run baseline moves a quarter of the way per session', () {
      var p = LoadProfile.fresh.withSessionBaseline(2.0);
      expect(p.baselineLogRatio, closeTo(2.0, 1e-9));
      expect(p.sessionCount, 1);

      p = p.withSessionBaseline(3.0);
      expect(p.baselineLogRatio, closeTo(2.25, 1e-9));

      p = p.withSessionBaseline(3.0);
      expect(p.baselineLogRatio, closeTo(2.4375, 1e-9),
          reason: 'a single strange day must not relocate a user');
      expect(p.sessionCount, 3);
    });

    test('a genuinely shifted user is followed, just slowly', () {
      var p = const LoadProfile(baselineLogRatio: 0.0);
      for (var i = 0; i < 12; i++) {
        p = p.withSessionBaseline(2.0);
      }
      expect(p.baselineLogRatio, greaterThan(1.9),
          reason: 'twelve consecutive sessions is a shift, not an anomaly');
    });
  });

  group('the index distribution', () {
    test('matches the sample statistics below the cap', () {
      var p = LoadProfile.fresh;
      for (final v in [10.0, 20.0, 30.0, 40.0, 50.0]) {
        p = p.withIndexFrame(v);
      }

      expect(p.indexMean, closeTo(30.0, 1e-9));
      // Population variance of 10..50: 200.
      expect(p.indexVariance, closeTo(200.0, 1e-9));
      expect(p.indexFrames, 5);
    });

    test('forgets past the cap, so a profile keeps tracking the user', () {
      var p = LoadProfile.fresh;
      for (var i = 0; i < LoadProfile.kMaxIndexFrames; i++) {
        p = p.withIndexFrame(30.0);
      }
      expect(p.indexMean, closeTo(30.0, 1e-9));
      expect(p.indexFrames, LoadProfile.kMaxIndexFrames);

      // Three cap-lengths at a new level. A plain running mean would still be
      // reading 60 here, and the thresholds derived from it would describe a
      // user who no longer exists.
      for (var i = 0; i < 3 * LoadProfile.kMaxIndexFrames; i++) {
        p = p.withIndexFrame(70.0);
      }
      expect(p.indexMean, greaterThan(65.0));
      expect(p.indexFrames, LoadProfile.kMaxIndexFrames,
          reason: 'the count saturates rather than growing without bound');
    });

    test('a non-finite frame is ignored rather than poisoning the profile', () {
      final p = LoadProfile.fresh
          .withIndexFrame(40.0)
          .withIndexFrame(double.nan)
          .withIndexFrame(double.infinity);

      expect(p.indexMean, closeTo(40.0, 1e-9));
      expect(p.indexFrames, 1);
    });
  });

  group('serialisation', () {
    test('round-trips through JSON', () {
      final original = _establishedUser(
          meanIndex: 63.5, sdIndex: 8.25, baselineLogRatio: -0.75);
      final back =
          LoadProfile.tryFromJson(jsonDecode(jsonEncode(original.toJson())));

      expect(back, isNotNull);
      expect(back!.baselineLogRatio, closeTo(-0.75, 1e-9));
      expect(back.indexMean, closeTo(63.5, 1e-9));
      expect(back.indexSd, closeTo(8.25, 1e-9));
      expect(back.indexFrames, original.indexFrames);
      expect(back.sessionCount, 20);
    });

    test('a user with no baseline yet round-trips as one', () {
      final back =
          LoadProfile.tryFromJson(jsonDecode(jsonEncode(LoadProfile.fresh.toJson())));
      expect(back!.hasBaseline, isFalse);
      expect(back.indexFrames, 0);
    });

    test('rejects or repairs what it cannot trust', () {
      expect(LoadProfile.tryFromJson(null), isNull);
      expect(LoadProfile.tryFromJson('nonsense'), isNull);

      // A hand-edited file costs the personalisation, not the app: anything
      // that survives parsing is clamped back into a usable range.
      final repaired = LoadProfile.tryFromJson({
        'baselineLogRatio': 'not-a-number',
        'indexMean': 55,
        'indexVariance': -9,
        'indexFrames': 999999999,
        'sessionCount': -4,
      });
      expect(repaired, isNotNull);
      expect(repaired!.hasBaseline, isFalse);
      expect(repaired.indexVariance, 0);
      expect(repaired.indexFrames, LoadProfile.kMaxIndexFrames);
      expect(repaired.sessionCount, 0);
    });
  });
}
