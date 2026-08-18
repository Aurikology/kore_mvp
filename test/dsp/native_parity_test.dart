import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/band_powers.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/dsp/dsp_engine.dart';
import 'package:kore/dsp/native_dsp_engine.dart';

/// The built DLL lives next to kore.exe. Tests run on the host VM from the
/// project root, so it has to be located explicitly rather than relying on
/// the executable-directory search order.
String? _findLibrary() {
  if (!Platform.isWindows) return null;
  for (final p in [
    'build/windows/x64/runner/Debug/kore_signal.dll',
    'build/windows/x64/runner/Release/kore_signal.dll',
  ]) {
    if (File(p).existsSync()) return File(p).absolute.path;
  }
  return null;
}

void main() {
  final libPath = _findLibrary();

  group('native/Dart parity', () {
    test('both engines produce identical band powers', () {
      final native = NativeDspEngine(libraryPath: libPath!);
      addTearDown(native.dispose);
      final dart = DartDspEngine();

      // A signal with content in both bands plus mains, so every stage of the
      // chain is exercised rather than just the passband.
      final rng = math.Random(12345);
      final nativeFrames = <BandPowers>[];
      final dartFrames = <BandPowers>[];

      const totalSamples = 4096;
      final block = <double>[];
      for (var n = 0; n < totalSamples; n++) {
        final t = n / DspConfig.sampleRateHz;
        final sample = 35.0 * math.sin(2 * math.pi * 10.2 * t) +
            18.0 * math.sin(2 * math.pi * 6.4 * t) +
            3.0 * math.sin(2 * math.pi * 60.0 * t) +
            12.0 * (rng.nextDouble() * 2 - 1) +
            5.0; // DC offset, so the blocker has something to remove

        block.add(sample);
        if (block.length == DspConfig.hopSize) {
          native.pushBlock(block);
          dart.pushBlock(block);

          final nf = native.takeFrame();
          final df = dart.takeFrame();
          if (nf != null) nativeFrames.add(nf);
          if (df != null) dartFrames.add(df);
          block.clear();
        }
      }

      expect(nativeFrames, isNotEmpty);
      expect(nativeFrames.length, dartFrames.length,
          reason: 'engines disagree on how many frames completed');

      for (var i = 0; i < nativeFrames.length; i++) {
        final n = nativeFrames[i];
        final d = dartFrames[i];
        // Same algorithm in double precision, so only float rounding should
        // separate them. A loose tolerance here would hide real drift.
        expect(n.theta, closeTo(d.theta, d.theta.abs() * 1e-9 + 1e-9),
            reason: 'theta mismatch at frame $i');
        expect(n.alpha, closeTo(d.alpha, d.alpha.abs() * 1e-9 + 1e-9),
            reason: 'alpha mismatch at frame $i');
      }
    });

    test('native engine reports the documented absolute power', () {
      final native = NativeDspEngine(libraryPath: libPath!);
      addTearDown(native.dispose);

      BandPowers? last;
      final block = <double>[];
      for (var n = 0; n < (DspConfig.sampleRateHz * 6).round(); n++) {
        block.add(50.0 * math.sin(2 * math.pi * 10.0 * n / DspConfig.sampleRateHz));
        if (block.length == DspConfig.hopSize) {
          native.pushBlock(block);
          last = native.takeFrame() ?? last;
          block.clear();
        }
      }

      // Same contract the Dart engine is held to: a pure sine of amplitude A
      // reports A^2/2, so 50 uV at 10 Hz reads 1250 uV^2 in alpha.
      expect(last, isNotNull);
      expect(last!.alpha, closeTo(1250.0, 125.0));
      expect(last.alpha, greaterThan(20 * last.theta));
    });

    test('reset clears filter state', () {
      final native = NativeDspEngine(libraryPath: libPath!);
      addTearDown(native.dispose);

      native.pushBlock(List<double>.filled(512, 500.0));
      expect(native.lastFiltered.abs(), greaterThan(0.0));

      native.reset();
      expect(native.lastFiltered, 0.0);
      expect(native.takeFrame(), isNull);
    });
  },
      skip: libPath == null
          ? 'kore_signal.dll not built - run: flutter build windows --debug'
          : false);
}
