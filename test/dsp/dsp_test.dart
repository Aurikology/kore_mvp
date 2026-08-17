import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/band_powers.dart';
import 'package:kore/dsp/biquad.dart';
import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/dsp/dsp_engine.dart';
import 'package:kore/dsp/hann.dart';

const fs = DspConfig.sampleRateHz;

/// Drive [engine] with a pure tone and return the last completed frame.
BandPowers _toneFrame(double freqHz, double amplitudeUv,
    {double seconds = 6.0}) {
  final engine = DartDspEngine();
  final total = (fs * seconds).round();
  BandPowers? last;

  // Push in 64-sample blocks, mirroring how the live source feeds the engine.
  final block = <double>[];
  for (var n = 0; n < total; n++) {
    block.add(amplitudeUv * math.sin(2 * math.pi * freqHz * n / fs));
    if (block.length == 64) {
      engine.pushBlock(block);
      last = engine.takeFrame() ?? last;
      block.clear();
    }
  }
  expect(last, isNotNull, reason: 'engine produced no frames');
  return last!;
}

double _rms(List<double> xs) =>
    math.sqrt(xs.map((x) => x * x).reduce((a, b) => a + b) / xs.length);

void main() {
  group('Hann window', () {
    test('periodic Hann satisfies sum(w^2) == 3N/8 exactly', () {
      final w = hannPeriodic(512);
      final sumSq = w.map((x) => x * x).reduce((a, b) => a + b);

      // 3*512/8 == 192. This identity only holds for the periodic window;
      // if someone "fixes" it to the symmetric N-1 form, every band power
      // silently gains a small bias and this test is the tripwire.
      expect(sumSq, closeTo(192.0, 1e-9));
      expect(hannSumSquares(512), closeTo(192.0, 1e-12));
      expect(w[0], 0.0);
    });
  });

  group('Band power', () {
    test('10 Hz tone lands in alpha, with correct absolute power', () {
      final p = _toneFrame(10.0, 50.0);

      expect(p.alpha, greaterThan(20 * p.theta),
          reason: 'alpha must dominate for a 10 Hz tone');

      // A pure sine of amplitude A reports its mean square, A^2/2.
      // 50 uV -> 2500/2 = 1250 uV^2. This single assertion validates the
      // whole chain: filtering, windowing, Goertzel, and normalisation.
      expect(p.alpha, closeTo(1250.0, 125.0));
    });

    test('6 Hz tone lands in theta, with correct absolute power', () {
      final p = _toneFrame(6.0, 30.0);

      expect(p.theta, greaterThan(20 * p.alpha),
          reason: 'theta must dominate for a 6 Hz tone');
      expect(p.theta, closeTo(450.0, 45.0)); // 30^2 / 2
    });

    test('60 Hz mains contributes essentially nothing to either band', () {
      final p = _toneFrame(60.0, 50.0);

      expect(p.theta, lessThan(1.0));
      expect(p.alpha, lessThan(1.0));
    });
  });

  group('Biquad notch', () {
    test('rejects 60 Hz but preserves the 10 Hz passband', () {
      for (final probe in [
        (freq: 60.0, shouldPass: false),
        (freq: 10.0, shouldPass: true),
      ]) {
        final notch =
            Biquad.notch(fs, DspConfig.mainsHz, DspConfig.mainsQ);
        final input = <double>[];
        final output = <double>[];

        for (var n = 0; n < 2048; n++) {
          final x = 50.0 * math.sin(2 * math.pi * probe.freq * n / fs);
          final y = notch.process(x);
          if (n >= 512) {
            // Discard the settling transient; a Q=20 notch rings for a while.
            input.add(x);
            output.add(y);
          }
        }

        final ratio = _rms(output) / _rms(input);
        if (probe.shouldPass) {
          // Both halves matter: a notch that also ate the passband would
          // sail through a stopband-only test.
          expect(ratio, closeTo(1.0, 0.05),
              reason: '10 Hz must survive the notch');
        } else {
          expect(ratio, lessThan(0.05), reason: '60 Hz must be rejected');
        }
      }
    });
  });

  group('DC blocker', () {
    test('removes a constant offset', () {
      final dc = DcBlocker(fs: fs);
      double y = 0;
      for (var n = 0; n < (fs * 3).round(); n++) {
        y = dc.process(100.0);
      }
      expect(y.abs(), lessThan(0.5));
    });

    test('leaves a 10 Hz tone essentially untouched', () {
      final dc = DcBlocker(fs: fs);
      final input = <double>[];
      final output = <double>[];

      for (var n = 0; n < 2048; n++) {
        final x = 50.0 * math.sin(2 * math.pi * 10.0 * n / fs);
        final yy = dc.process(x);
        if (n >= 512) {
          input.add(x);
          output.add(yy);
        }
      }
      expect(_rms(output) / _rms(input), closeTo(1.0, 0.02));
    });
  });

  group('Cognitive Load Index', () {
    /// Feed [frames] synthetic frames at a fixed theta/alpha and return the
    /// index afterwards.
    double drive(CognitiveLoadIndex cli, double theta, double alpha, int frames,
        {void Function(double)? onEach}) {
      for (var i = 0; i < frames; i++) {
        cli.update(BandPowers(
            theta: theta, alpha: alpha, total: theta + alpha, frameIndex: i));
        onEach?.call(cli.value);
      }
      return cli.value;
    }

    test('calibrates, then reads calm near the low end', () {
      final cli = CognitiveLoadIndex();
      expect(cli.state, LoadState.calibrating);

      // 15 s of baseline at 4 Hz.
      drive(cli, 71.0, 630.0, 60);
      expect(cli.state, LoadState.steady);
      expect(cli.isCalibrated, isTrue);

      final calm = drive(cli, 71.0, 630.0, 40);
      expect(calm, inInclusiveRange(20.0, 35.0));
    });

    test('rises into strain under load and recovers, with hysteresis', () {
      final cli = CognitiveLoadIndex();
      drive(cli, 71.0, 630.0, 60); // baseline

      // High theta, suppressed alpha - the signature of cognitive load.
      final loaded = drive(cli, 493.0, 85.0, 60);
      expect(loaded, greaterThan(70.0));
      expect(cli.state, LoadState.strain);

      final recovered = drive(cli, 71.0, 630.0, 60);
      expect(recovered, lessThan(60.0));
      expect(cli.state, LoadState.steady);
    });

    test('stays inside [0,100] and finite under adversarial input', () {
      final cli = CognitiveLoadIndex();
      drive(cli, 71.0, 630.0, 60);

      final probes = <(double, double)>[
        (0.0, 0.0), // silence: both bands empty
        (1e12, 1e-12), // absurd ratio
        (1e-12, 1e12), // absurd inverse
        (0.0, 1000.0), // log of zero numerator
        (1000.0, 0.0), // divide by zero
      ];

      for (final (theta, alpha) in probes) {
        drive(cli, theta, alpha, 10, onEach: (v) {
          expect(v.isFinite, isTrue, reason: 'CLI went non-finite');
          expect(v, inInclusiveRange(0.0, 100.0));
        });
      }
    });
  });
}
