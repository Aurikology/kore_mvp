import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kore/services/eeg_data_stream.dart';
import 'package:kore/services/history_store.dart';
import 'package:kore/services/signal_quality.dart';
import 'package:kore/session/kore_session.dart';
import 'package:kore/sources/simulated_eeg_source.dart';
import 'package:kore/sources/source_link.dart';

/// What happens to a session the operating system suspends.
///
/// On a desktop the app is a window that stays open. On a phone it is
/// suspended constantly and without being asked, and the reading either
/// survives that honestly or quietly invents a line across it.
void main() {
  /// A session on the test's clock, in both senses: the source's sample clock
  /// and the wall clock the suspend gap is measured against.
  ({KoreSession session, SimulatedEegSource source}) build(FakeAsync async) {
    final source = SimulatedEegSource(
      autoTimeline: false,
      elapsedMicros: () => async.elapsed.inMicroseconds,
    );
    final session = KoreSession(
      source: source,
      now: () => DateTime.fromMicrosecondsSinceEpoch(async.elapsed.inMicroseconds),
    );
    return (session: session, source: source);
  }

  void advance(FakeAsync async, Duration d) {
    async.elapse(d);
    async.flushMicrotasks();
  }

  test('pausing stops the samples arriving', () {
    fakeAsync((async) {
      final (:session, :source) = build(async);
      final blocks = <SampleBlock>[];
      source.sampleBlocks.listen(blocks.add);

      session.start();
      advance(async, const Duration(seconds: 1));
      expect(blocks, isNotEmpty);

      session.pause();
      advance(async, const Duration(seconds: 1));
      final delivered = blocks.length;

      advance(async, const Duration(seconds: 5));
      expect(blocks.length, delivered,
          reason: 'a suspended app is not measuring, and should not be '
              'holding a subscription open pretending otherwise');
      expect(session.linkState, SourceLinkState.idle);

      session.dispose();
    });
  });

  test('resuming picks the link back up', () {
    fakeAsync((async) {
      final (:session, :source) = build(async);
      session.start();
      advance(async, const Duration(seconds: 1));

      session.pause();
      advance(async, const Duration(seconds: 30));
      session.resume();
      advance(async, const Duration(milliseconds: 100));

      expect(session.linkState, SourceLinkState.streaming);
      session.dispose();
    });
  });

  group('a gap longer than one analysis window', () {
    test('puts a hole in the history rather than a line across it', () {
      fakeAsync((async) {
        final (:session, :source) = build(async);
        session.start();
        // Past calibration - 2 s to fill the window, then 15 s of baseline -
        // because nothing enters the history until the index means something.
        advance(async, const Duration(seconds: 25));

        final before = session.history.length;
        expect(before, greaterThan(4));
        expect(session.history.every((v) => v != null), isTrue);

        session.pause();
        advance(async, const Duration(minutes: 4));
        session.resume();
        advance(async, const Duration(milliseconds: 100));

        final holes = session.history.where((v) => v == null).length;
        expect(holes, 1,
            reason: 'the minutes nobody measured must not be joined up into '
                'a line that reads as calm');

        // And the readings from before it are still there. Refusing to draw
        // across a gap is not a reason to throw away what was measured.
        expect(session.history.length, greaterThan(before));
      });
    });

    test('will not believe a frame until a clean window has passed', () {
      fakeAsync((async) {
        final (:session, :source) = build(async);
        session.start();
        advance(async, const Duration(seconds: 10));
        expect(session.isReadingTrustworthy, isTrue);

        session.pause();
        advance(async, const Duration(minutes: 4));
        session.resume();
        advance(async, const Duration(milliseconds: 200));

        expect(session.isReadingTrustworthy, isFalse);
        expect(session.signalFaults, contains(SignalFault.settling));
        expect(session.signalFaults, isNot(contains(SignalFault.dropout)),
            reason: 'nothing was dropped by the radio, and "move closer to '
                'the device" is not the fix for having been in a pocket');

        // It comes back on its own once a full window of samples has passed.
        advance(async, const Duration(seconds: 3));
        expect(session.isReadingTrustworthy, isTrue);
      });
    });

    test('does not stack holes when it happens twice', () {
      fakeAsync((async) {
        final (:session, :source) = build(async);
        session.start();
        advance(async, const Duration(seconds: 25));

        session.pause();
        advance(async, const Duration(minutes: 2));
        session.resume();
        // Resumed and immediately suspended again, with no frame in between.
        session.pause();
        advance(async, const Duration(minutes: 2));
        session.resume();
        advance(async, const Duration(milliseconds: 100));

        expect(session.history.where((v) => v == null).length, 1,
            reason: 'two holes with nothing between them is one hole');
        session.dispose();
      });
    });
  });

  test('a gap shorter than one analysis window is left alone', () {
    fakeAsync((async) {
      final (:session, :source) = build(async);
      session.start();
      advance(async, const Duration(seconds: 25));

      session.pause();
      // Half a window. A phone flickering in and out of the background at
      // this rate would spend its whole life settling.
      advance(async, const Duration(milliseconds: 900));
      session.resume();
      advance(async, const Duration(milliseconds: 100));

      expect(session.history.every((v) => v != null), isTrue);
      expect(session.signalFaults, isNot(contains(SignalFault.settling)));
      session.dispose();
    });
  });

  group('where the history lives on Android', () {
    test('is the files directory, not the cache directory beside it', () {
      // Flutter points TMPDIR at the app's cache directory, and Android
      // deletes those under storage pressure without asking.
      expect(
        HistoryStore.androidBase('/data/user/0/com.kore.app/cache').path,
        '/data/user/0/com.kore.app/files/KORE',
      );
    });

    test('leaves an unfamiliar path alone rather than guessing at it', () {
      // Writing outside the app's own sandbox is worse than losing history to
      // a cleared cache, so anything unexpected keeps the old behaviour.
      expect(HistoryStore.androidBase('/tmp').path, '/tmp/kore');
      expect(HistoryStore.androidBase('/data/local/tmp').path,
          '/data/local/tmp/kore');
    });

    test('does not mistake a path that merely contains the word', () {
      expect(HistoryStore.androidBase('/data/cache/user/0/app').path,
          '/data/cache/user/0/app/kore');
    });
  });

  test('resuming without having paused does nothing', () {
    fakeAsync((async) {
      final (:session, :source) = build(async);
      session.start();
      advance(async, const Duration(seconds: 25));

      final before = session.history.length;
      session.resume();
      advance(async, const Duration(milliseconds: 100));

      expect(session.history.where((v) => v == null), isEmpty);
      expect(session.history.length, greaterThanOrEqualTo(before));
      session.dispose();
    });
  });
}
