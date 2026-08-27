import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/dsp/dsp_engine.dart';
import 'package:kore/services/signal_quality.dart';
import 'package:kore/session/kore_session.dart';
import 'package:kore/sources/simulated_eeg_source.dart';

/// A crystal 2% fast, and a device that needs three seconds of streaming
/// before it can say so - which is what a BLE source deriving its rate from
/// packet arrival times looks like.
const double _fastCrystalHz = 256.0 * 1.02;
const double _measureDelaySeconds = 3.0;

SimulatedEegSource _lateSource(
  FakeAsync async, {
  double error = 0.02,
  double delay = _measureDelaySeconds,
}) {
  final source = SimulatedEegSource(
    elapsedMicros: () => async.elapsed.inMicroseconds,
  );
  source.setSampleRateError(error);
  source.measureRateAfter(delay);
  return source;
}

void _advance(FakeAsync async, Duration d) {
  async.elapse(d);
  async.flushMicrotasks();
}

KoreSession _started(FakeAsync async, SimulatedEegSource source) {
  final session = KoreSession(source: source);
  session.start();
  async.flushMicrotasks();
  return session;
}

void main() {
  group('a source that cannot report its rate yet', () {
    test('says so, and reports its nominal in the meantime', () {
      fakeAsync((async) {
        final source = _lateSource(async);
        expect(source.rateMeasured, isFalse);
        expect(source.effectiveSampleRateHz, 256.0,
            reason: 'the nominal, standing in for a measurement');

        source.start();
        _advance(async, const Duration(seconds: 1));
        expect(source.rateMeasured, isFalse);

        _advance(async, const Duration(seconds: 3));
        expect(source.rateMeasured, isTrue);
        expect(source.effectiveSampleRateHz, closeTo(_fastCrystalHz, 1e-9));
        source.dispose();
      });
    });

    test('the crystal was fast the whole time, not only once measured', () {
      // The simulator must not cheat by actually sampling at 256 until it
      // notices. A device that reported a nominal it was also obeying would
      // be a simulator agreeing with itself and with nothing else.
      fakeAsync((async) {
        final source = _lateSource(async);
        var delivered = 0;
        source.sampleBlocks.listen((b) => delivered += b.length);
        source.start();
        _advance(async, const Duration(seconds: 2));

        expect(source.rateMeasured, isFalse);
        expect(delivered / 2.0, closeTo(_fastCrystalHz, 3.0),
            reason: 'samples arrive at the true rate from the first one');
        source.dispose();
      });
    });

    test('a source that knows its crystal reports no delay at all', () {
      fakeAsync((async) {
        final source = SimulatedEegSource(
          elapsedMicros: () => async.elapsed.inMicroseconds,
        );
        expect(source.rateMeasured, isTrue);
        source.dispose();
      });
    });
  });

  group('the session re-tunes when the measurement lands', () {
    test('opens on the nominal, and says the tuning is provisional', () {
      fakeAsync((async) {
        final session = KoreSession(source: _lateSource(async));
        expect(session.tunedSampleRateHz, DspConfig.nominalSampleRateHz);
        expect(session.rateTuningProvisional, isTrue);
        session.dispose();
      });
    });

    test('rebuilds the whole analysis once the rate arrives', () {
      fakeAsync((async) {
        final session = _started(async, _lateSource(async));
        final firstEngine = session.engine;
        _advance(async, const Duration(seconds: 5));

        expect(session.rateTuningProvisional, isFalse);
        expect(session.tunedSampleRateHz, closeTo(_fastCrystalHz, 1e-9));
        expect(session.engine, isNot(same(firstEngine)),
            reason: 'a rebuilt engine, not a re-tuned one');

        // All four, or the index counts frames at a rate the engine no longer
        // produces them at.
        expect(session.engine.config.sampleRateHz, session.tunedSampleRateHz);
        expect(session.index.config.sampleRateHz, session.tunedSampleRateHz);
        expect(session.predictor.config.sampleRateHz, session.tunedSampleRateHz);
        expect(session.signalGate.config.sampleRateHz, session.tunedSampleRateHz);
        session.dispose();
      });
    });

    test('calibrates and reads, on a device that could not answer up front',
        () {
      // The end-to-end case this exists for. Without the re-tune the session
      // would analyse a 261.12 Hz stream with a 256 Hz notch for the rest of
      // its life, and the gate would band the difference as drift.
      fakeAsync((async) {
        final session = _started(async, _lateSource(async));
        _advance(async, const Duration(seconds: 30));

        expect(session.isCalibrated, isTrue);
        expect(session.signalQualityLevel, SignalQualityLevel.good);
        expect(session.signalFaults, isEmpty);
        expect(session.isReadingTrustworthy, isTrue);
        session.dispose();
      });
    });

    test('a sub-band crystal still triggers the re-tune', () {
      // 0.5% never crosses a quality band, so nothing about the report's
      // *level* changes when the measurement lands. It is still the difference
      // between a notch on 60.000 Hz and a fifth of the mains getting through,
      // so the session has to hear about it anyway.
      fakeAsync((async) {
        final session = _started(async, _lateSource(async, error: 0.005));
        _advance(async, const Duration(seconds: 5));

        expect(session.rateTuningProvisional, isFalse);
        expect(session.tunedSampleRateHz, closeTo(256.0 * 1.005, 1e-9));
        expect(session.signalFaults, isEmpty);
        session.dispose();
      });
    });

    test('it happens once, and a later drift is banded rather than followed',
        () {
      fakeAsync((async) {
        final source = _lateSource(async);
        final session = _started(async, source);
        _advance(async, const Duration(seconds: 30));
        expect(session.isCalibrated, isTrue);
        final tuned = session.tunedSampleRateHz;

        // The crystal warms up and walks off where it was tuned.
        source.setSampleRateError(0.05);
        _advance(async, const Duration(seconds: 5));

        expect(session.tunedSampleRateHz, tuned,
            reason: 'following drift is a different feature, still deferred');
        expect(session.signalFaults, contains(SignalFault.sampleRateDrift));
        session.dispose();
      });
    });

    test('a measurement arriving after calibration is refused, not honoured',
        () {
      // Refusing keeps a baseline the user waited fifteen seconds for. The
      // drift banding then reports the difference, which is the behaviour that
      // existed before any of this and is honest rather than silent.
      fakeAsync((async) {
        final session = _started(async, _lateSource(async, delay: 40));
        _advance(async, const Duration(seconds: 30));
        expect(session.isCalibrated, isTrue);
        expect(session.tunedSampleRateHz, DspConfig.nominalSampleRateHz);

        _advance(async, const Duration(seconds: 15));
        expect(session.rateTuningProvisional, isFalse,
            reason: 'the source answered; the answer was refused as too late');
        expect(session.tunedSampleRateHz, DspConfig.nominalSampleRateHz);
        expect(session.signalFaults, contains(SignalFault.sampleRateDrift));
        session.dispose();
      });
    });

    test('an injected engine is never replaced', () {
      fakeAsync((async) {
        final engine = DartDspEngine();
        final session = KoreSession(
          source: _lateSource(async),
          engine: engine,
        );
        expect(session.rateTuningProvisional, isFalse);
        session.start();
        async.flushMicrotasks();
        _advance(async, const Duration(seconds: 10));

        expect(session.engine, same(engine));
        expect(session.tunedSampleRateHz, DspConfig.nominalSampleRateHz);
        session.dispose();
      });
    });

    test('a source that knows its crystal is tuned once and never revisited',
        () {
      fakeAsync((async) {
        final source = SimulatedEegSource(
          elapsedMicros: () => async.elapsed.inMicroseconds,
        );
        source.setSampleRateError(0.02);
        final session = _started(async, source);
        final engine = session.engine;

        expect(session.rateTuningProvisional, isFalse);
        expect(session.tunedSampleRateHz, closeTo(_fastCrystalHz, 1e-9));
        _advance(async, const Duration(seconds: 10));
        expect(session.engine, same(engine));
        session.dispose();
      });
    });
  });
}
