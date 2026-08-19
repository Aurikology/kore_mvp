import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/dsp/dsp_engine.dart';
import 'package:kore/sources/scenario_eeg_generator.dart';

/// The figures in the README and the project briefing, pinned.
///
/// They were reproducible from `tool/cli_probe.dart` and nowhere else, which
/// meant "a fresh user with a good signal reads 0.15 -> 29" was a claim held
/// up by a console tool nobody runs. Quality handling is the change that made
/// that worth fixing: it touches the generator, the index and the session, and
/// the promise it has to keep is that none of it is visible when the signal is
/// fine.
double _mean(
  ScenarioEEGGenerator gen,
  DartDspEngine engine,
  CognitiveLoadIndex cli,
  double seconds,
) {
  final blocks = (seconds * DspConfig.framesPerSecond).round();
  var sum = 0.0;
  var n = 0;

  for (var b = 0; b < blocks; b++) {
    engine.pushBlock(List<double>.generate(
        DspConfig.hopSize, (_) => gen.nextSampleMicrovolts()));
    final frame = engine.takeFrame();
    if (frame == null) continue;
    cli.update(frame);
    if (cli.isCalibrated) {
      sum += cli.value;
      n++;
    }
  }
  return n == 0 ? double.nan : sum / n;
}

void main() {
  test('a fresh user reproduces every published figure', () {
    // Exactly the probe's rig: same seed, same tracker, same settle time.
    final gen = ScenarioEEGGenerator(seed: 1, tauSeconds: 0.5);
    final engine = DartDspEngine();
    final cli = CognitiveLoadIndex();

    expect(cli.strainEnter, 70.0, reason: 'enter 70 is the published number');
    expect(cli.strainExit, 60.0, reason: 'and leave 60 is the other one');
    expect(cli.isPersonalised, isFalse);

    gen.snapLoad(0.15);
    _mean(gen, engine, cli, 25);
    expect(cli.baseline, closeTo(-2.273, 0.001));

    const expected = <(double, int)>[
      (0.15, 29),
      (0.50, 55),
      (0.75, 72),
      (0.90, 81),
    ];
    for (final (load, published) in expected) {
      gen.snapLoad(load);
      _mean(gen, engine, cli, 12); // settle
      final reading = _mean(gen, engine, cli, 12);
      expect(reading.round(), published,
          reason: 'load $load read $reading, not $published');
    }
  });
}
