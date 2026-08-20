import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/dsp/focus_crash_predictor.dart';
import 'package:kore/services/signal_quality.dart';
import 'package:kore/session/kore_session.dart';
import 'package:kore/sources/simulated_eeg_source.dart';

/// The same rig as `reset_loop_test.dart`: fakeAsync's clock drives the
/// simulated source, so a 75 s journey runs in about a second.
KoreSession _session(FakeAsync async) => KoreSession(
      source: SimulatedEegSource(
        elapsedMicros: () => async.elapsed.inMicroseconds,
      ),
      engine: DartDspEngine(),
    );

void _advance(FakeAsync async, Duration d) {
  async.elapse(d);
  async.flushMicrotasks();
}

/// Runs a session to a settled, calibrated, believable state.
KoreSession _calibrated(FakeAsync async) {
  final session = _session(async);
  session.start();
  async.flushMicrotasks();
  _advance(async, const Duration(seconds: 25));
  expect(session.isCalibrated, isTrue);
  return session;
}

void main() {
  test('a clean signal says nothing about itself', () {
    fakeAsync((async) {
      final session = _calibrated(async);
      _advance(async, const Duration(seconds: 10));

      expect(session.signalQualityLevel, SignalQualityLevel.good);
      expect(session.signalFaults, isEmpty);
      expect(session.isReadingTrustworthy, isTrue);
      expect(session.signalDegraded, isFalse);
      expect(session.calibrationStalled, isFalse);
      expect(session.electrodeContact, 1.0);
      expect(session.measuredSampleRateHz, 256.0);

      session.dispose();
    });
  });

  test('a detached electrode is not published as a reading', () {
    fakeAsync((async) {
      final session = _calibrated(async);
      _advance(async, const Duration(seconds: 10));

      final held = session.cognitiveLoad;
      final trace = session.history.length;

      session.simulateDetachedElectrode();
      _advance(async, const Duration(seconds: 30));

      expect(session.isReadingTrustworthy, isFalse);
      expect(session.signalFaults, contains(SignalFault.electrodeDetached));
      expect(session.cognitiveLoad, closeTo(held, 1e-9),
          reason: 'the number is the last real one, not the artifact');
      expect(session.loadState, isNot(LoadState.strain),
          reason: 'and the app must not offer a reset for a loose headband');
      expect(session.history.length, trace,
          reason: 'a held value in the trend reads as a measurement of calm');
      expect(session.crashForecast.status, CrashForecastStatus.uncalibrated,
          reason: 'a forecast fitted across the gap warns about the electrode');

      session.dispose();
    });
  });

  test('the daily rollup does not absorb what it could not see', () {
    fakeAsync((async) {
      final session = _calibrated(async);
      _advance(async, const Duration(seconds: 20));
      session.flushState();
      final measured = session.dailyLoad.latest!.frames;
      expect(measured, greaterThan(0));

      session.simulateDetachedElectrode();
      _advance(async, const Duration(seconds: 30));
      session.flushState();

      expect(session.dailyLoad.latest!.frames, measured,
          reason: 'the longitudinal record is the last place an artifact '
              'should be able to hide');

      session.dispose();
    });
  });

  test('the personal profile learns nothing from a bad electrode', () {
    fakeAsync((async) {
      final session = _calibrated(async);
      _advance(async, const Duration(seconds: 10));
      final frames = session.loadProfile.indexFrames;

      session.simulateDetachedElectrode();
      _advance(async, const Duration(seconds: 30));

      expect(session.loadProfile.indexFrames, frames);
      session.dispose();
    });
  });

  test('a baseline is never captured through a bad electrode', () {
    fakeAsync((async) {
      final session = _session(async);
      session.start();
      async.flushMicrotasks();
      session.simulateDetachedElectrode();

      _advance(async, const Duration(seconds: 60));
      expect(session.isCalibrated, isFalse,
          reason: 'a poisoned baseline would misread every frame after it');
      expect(session.calibrationStalled, isTrue,
          reason: 'a countdown that has stopped counting needs an explanation');
      expect(session.signalFaults, contains(SignalFault.electrodeDetached));

      session.simulateGoodContact();
      _advance(async, const Duration(seconds: 25));
      expect(session.isCalibrated, isTrue);
      expect(session.calibrationStalled, isFalse);

      session.dispose();
    });
  });

  test('a dropout suspends the reading, then clears', () {
    fakeAsync((async) {
      final session = _calibrated(async);
      _advance(async, const Duration(seconds: 5));
      expect(session.isReadingTrustworthy, isTrue);

      session.simulateDropout(samples: 256);
      _advance(async, const Duration(milliseconds: 500));
      expect(session.isReadingTrustworthy, isFalse);
      expect(session.signalFaults, contains(SignalFault.dropout));

      // One second of lost samples, then a full analysis window to flush the
      // splice out of it.
      _advance(async, const Duration(seconds: 4));
      expect(session.isReadingTrustworthy, isTrue);
      expect(session.signalFaults, isEmpty);

      session.dispose();
    });
  });

  test('a slipping band degrades the reading without withholding it', () {
    fakeAsync((async) {
      final session = _calibrated(async);
      session.simulatePoorContact();
      _advance(async, const Duration(seconds: 10));

      expect(session.signalQualityLevel, SignalQualityLevel.degraded);
      expect(session.signalDegraded, isTrue);
      expect(session.isReadingTrustworthy, isTrue,
          reason: 'a warning worth acting on is not withheld over a slipping '
              'band - it is published with the caveat attached');
      expect(session.signalFaults, {SignalFault.poorContact});

      session.dispose();
    });
  });

  group('a reset is only logged when it was measured', () {
    test('not when it began through a bad signal', () {
      fakeAsync((async) {
        final session = _calibrated(async);
        session.simulateDetachedElectrode();
        _advance(async, const Duration(seconds: 5));

        session.startReset();
        _advance(async, const Duration(seconds: 61));

        expect(session.resetActive, isFalse);
        expect(session.hasUncommittedReset, isFalse,
            reason: 'a before/after pair over an artifact is not a metric');
        expect(session.awaitingCheckIn, isFalse);

        session.commitReset(clarity: 5);
        async.flushMicrotasks();
        expect(session.resetHistory.totalCount, 0);

        session.dispose();
      });
    });

    test('not when the signal failed part way through it', () {
      fakeAsync((async) {
        final session = _calibrated(async);
        session.simulateStrain();
        _advance(async, const Duration(seconds: 15));

        session.startReset();
        _advance(async, const Duration(seconds: 20));
        session.simulateDetachedElectrode();
        _advance(async, const Duration(seconds: 10));
        session.simulateGoodContact();
        _advance(async, const Duration(seconds: 35));

        expect(session.resetActive, isFalse);
        expect(session.hasUncommittedReset, isFalse,
            reason: 'the drop was measured against a number that was frozen '
                'for ten of the sixty seconds');

        session.dispose();
      });
    });

    test('but is when the signal held', () {
      fakeAsync((async) {
        final session = _calibrated(async);
        session.simulateStrain();
        _advance(async, const Duration(seconds: 15));

        session.startReset();
        _advance(async, const Duration(seconds: 61));

        expect(session.awaitingCheckIn, isTrue);
        expect(session.pendingDrop, greaterThan(0));

        session.commitReset(clarity: 4);
        async.flushMicrotasks();
        expect(session.resetHistory.totalCount, 1);

        session.dispose();
      });
    });
  });
}
