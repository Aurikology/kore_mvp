import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/dsp/dsp_engine.dart';
import 'package:kore/dsp/load_profile.dart';
import 'package:kore/services/history_store.dart';
import 'package:kore/services/eeg_data_stream.dart';
import 'package:kore/services/signal_quality.dart';
import 'package:kore/session/kore_history.dart';
import 'package:kore/session/reset_record.dart';
import 'package:kore/session/kore_session.dart';
import 'package:kore/sources/demo_controls.dart';
import 'package:kore/sources/eeg_source.dart';
import 'package:kore/sources/simulated_eeg_source.dart';
import 'package:kore/sources/source_link.dart';

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

    test('it fires once even while there is still no baseline to protect', () {
      // The one-shot flag on its own. The sibling test above is stopped by the
      // isCalibrated guard, so it would still pass with the once-ness removed;
      // here the crystal moves again *before* calibration completes, which is
      // the only window where the two guards can be told apart. Following that
      // second move is drift-chasing, and drift-chasing is still deferred.
      fakeAsync((async) {
        final source = _lateSource(async);
        final session = _started(async, source);
        _advance(async, const Duration(seconds: 5));
        expect(session.rateTuningProvisional, isFalse);
        expect(session.tunedSampleRateHz, closeTo(_fastCrystalHz, 1e-9));

        source.setSampleRateError(0.05);
        _advance(async, const Duration(seconds: 4));

        expect(session.isCalibrated, isFalse,
            reason: 'or the isCalibrated guard is what stopped it, not the flag');
        expect(session.tunedSampleRateHz, closeTo(_fastCrystalHz, 1e-9),
            reason: 'the one shot was spent on the first measurement');
        session.dispose();
      });
    });

    test('a rebuilt index keeps the profile that came off disk', () {
      // Requirement 5's other half. A rebuilt index with a fresh profile would
      // silently drop the user's own thresholds and read as a first-ever
      // session - and every other test here runs with no store, so the
      // re-adopt branch would never execute.
      //
      // A stub store rather than a real file: `start()` awaits the load, and
      // real disk I/O never completes inside fakeAsync, which the simulated
      // source needs for its clock.
      fakeAsync((async) {
        final session = KoreSession(
          source: _lateSource(async),
          store: _StubStore(_personalised),
        );
        session.start();
        async.flushMicrotasks();
        expect(session.thresholdsPersonalised, isTrue,
            reason: 'the profile arrived before the re-tune');
        final personalised = session.strainEnter;

        _advance(async, const Duration(seconds: 6));
        expect(session.rateTuningProvisional, isFalse,
            reason: 'the rebuild happened');
        expect(session.tunedSampleRateHz, closeTo(_fastCrystalHz, 1e-9));

        expect(session.loadProfile.indexFrames, _personalised.indexFrames);
        expect(
            session.loadProfile.baselineLogRatio, _personalised.baselineLogRatio);
        expect(session.thresholdsPersonalised, isTrue,
            reason: 'a rebuilt index that lost the profile reads as a '
                'first-ever session');
        expect(session.strainEnter, personalised);
        session.dispose();
      });
    });

    test('a rebuilt gate does not announce a clean signal over a live fault',
        () {
      // A fresh SignalQualityGate holds SignalQuality.unreported, which reads
      // as good. On the block and quality paths the next line corrects it; a
      // re-tune reached from the link stream publishes with nothing in
      // between, and a dropped link delivers no blocks to correct it with.
      fakeAsync((async) {
        final source = _lateSource(async);
        final session = _started(async, source);
        _advance(async, const Duration(seconds: 1));
        source.detachElectrode();
        _advance(async, const Duration(seconds: 4));

        expect(session.rateTuningProvisional, isFalse,
            reason: 'the rebuild happened with a fault standing');
        expect(session.signalFaults, isNotEmpty);
        expect(session.isReadingTrustworthy, isFalse);
        session.dispose();
      });
    });

    test('the suspend-gap threshold follows the new tuning, not the old', () {
      // `_minimumGap` is one analysis window: 2.000 s at the nominal rate but
      // 1.961 s at 261.12 Hz. Cached on first read - which happens inside
      // resume() - it would keep the pre-re-tune value for the rest of the
      // session, and a gap between the two lengths would be spliced instead of
      // refused. A suspension in the first seconds is exactly the window this
      // whole commit is about, so the cache would be primed by the very case
      // it then gets wrong.
      fakeAsync((async) {
        var clock = DateTime(2026, 3, 1, 9);
        final source = _lateSource(async);
        final session = KoreSession(source: source, now: () => clock);
        session.start();
        async.flushMicrotasks();

        // Suspend and resume once *before* the measurement lands, priming any
        // cache against the provisional nominal tuning.
        _advance(async, const Duration(seconds: 1));
        session.pause();
        async.flushMicrotasks();
        clock = clock.add(const Duration(milliseconds: 500));
        session.resume();
        async.flushMicrotasks();

        _advance(async, const Duration(seconds: 6));
        expect(session.rateTuningProvisional, isFalse);
        expect(session.config.windowSeconds, closeTo(1.9608, 1e-4));

        // A gap longer than the new window but shorter than the old one. It
        // spans an analysis window on this device and must be refused.
        session.pause();
        async.flushMicrotasks();
        clock = clock.add(const Duration(milliseconds: 1980));
        session.resume();
        async.flushMicrotasks();

        expect(session.signalFaults, contains(SignalFault.settling),
            reason: '1980 ms spans a 1961 ms window; judged against the stale '
                '2000 ms it would have been spliced in silently');
        session.dispose();
      });
    });

    test('a link-only announcement does not publish a clean gate', () async {
      // Reached with a hand-built source rather than the simulator, which
      // always force-publishes the transition on the quality stream. A source
      // that announces on the link stream alone leaves `_onLink` to re-tune
      // and notify with nothing in between, and a fresh gate reads as good.
      //
      // Worth having for a second reason: it is the only place in the suite
      // that implements `EegSource` from scratch, which is the claim the seam
      // makes about BLE being a drop-in.
      final source = _LinkOnlySource();
      final session = KoreSession(source: source);
      addTearDown(session.dispose);
      await session.start();

      expect(session.rateTuningProvisional, isTrue);
      source.announceMeasuredRateOnLinkOnly();
      // Broadcast delivery is asynchronous; let the link event land.
      await Future<void>.delayed(Duration.zero);

      expect(session.rateTuningProvisional, isFalse, reason: 're-tuned');
      expect(session.tunedSampleRateHz, closeTo(_fastCrystalHz, 1e-9));
      expect(session.isReadingTrustworthy, isFalse,
          reason: 'the electrode is off and the rebuilt gate must say so');
      expect(session.signalFaults, isNotEmpty);
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

/// Enough frames on record that the thresholds have moved off the published
/// defaults, so losing the profile is visible in behaviour and not only in a
/// field.
const LoadProfile _personalised = LoadProfile(
  baselineLogRatio: -2.0,
  indexMean: 74.0,
  indexVariance: 16.0,
  indexFrames: CognitiveLoadIndex.kFramesBeforePersonalising + 500,
  sessionCount: 9,
);

/// A store that answers from memory, so the load completes in a microtask and
/// fakeAsync can flush it.
class _StubStore extends HistoryStore {
  final LoadProfile profile;

  _StubStore(this.profile) : super(File('unused-by-this-stub'));

  @override
  Future<KoreHistory> loadDocument() async => KoreHistory(
        resets: ResetHistory.empty,
        profile: profile,
        days: DailyLoadLog.empty,
        app: const AppState(),
      );

  @override
  Future<void> saveState({
    required LoadProfile profile,
    required DailyLoadLog days,
  }) async {}
}

/// A source that reports its measured rate only through the link stream, which
/// the simulator never does. Minimal on purpose: everything not under test is
/// the least it can legally be.
class _LinkOnlySource implements EegSource {
  final _blocks = StreamController<SampleBlock>.broadcast();
  final _quality = StreamController<SignalQuality>.broadcast();
  final _link = StreamController<SourceLink>.broadcast();

  bool _measured = false;

  /// An electrode that is off, standing throughout, so a gate that reset
  /// itself to `unreported` reads as good and the test can see it.
  @override
  SignalQuality get quality => const SignalQuality(
        contact: 0.0,
        measuredRateHz: 256.0,
        referenceRateHz: 256.0,
      );

  void announceMeasuredRateOnLinkOnly() {
    _measured = true;
    _link.add(const SourceLink(state: SourceLinkState.streaming));
  }

  @override
  bool get rateMeasured => _measured;

  @override
  double get effectiveSampleRateHz => _measured ? _fastCrystalHz : 256.0;

  @override
  int get samplingRateHz => 256;

  @override
  String get label => 'Link-only test source';

  @override
  DemoControls? get demo => null;

  @override
  SourceLink get link => const SourceLink(state: SourceLinkState.streaming);

  @override
  Stream<SampleBlock> get sampleBlocks => _blocks.stream;

  @override
  Stream<SignalQuality> get qualityUpdates => _quality.stream;

  @override
  Stream<SourceLink> get linkUpdates => _link.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  void dispose() {
    _blocks.close();
    _quality.close();
    _link.close();
  }
}
