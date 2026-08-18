import 'package:flutter_test/flutter_test.dart';
import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/dsp/dsp_engine.dart';
import 'package:kore/sources/scenario_eeg_generator.dart';

/// Runs [seconds] of generator output through the full pipeline and returns
/// the mean index over that stretch (frames before the baseline lands are
/// skipped, since the index is undefined then).
double _run(
  ScenarioEEGGenerator gen,
  DartDspEngine engine,
  CognitiveLoadIndex cli,
  double seconds,
) {
  final blocks = (seconds * DspConfig.framesPerSecond).round();
  final samplesPerBlock = DspConfig.hopSize;

  var sum = 0.0;
  var count = 0;

  for (var b = 0; b < blocks; b++) {
    final block = List<double>.generate(
        samplesPerBlock, (_) => gen.nextSampleMicrovolts());
    engine.pushBlock(block);

    final frame = engine.takeFrame();
    if (frame == null) continue;
    cli.update(frame);

    if (cli.isCalibrated) {
      sum += cli.value;
      count++;
    }
  }

  return count == 0 ? double.nan : sum / count;
}

void main() {
  test('scenario generator drives the index from calm to strain', () {
    // Seeded so the assertion is deterministic across runs.
    final gen = ScenarioEEGGenerator(seed: 42, tauSeconds: 0.5);
    final engine = DartDspEngine();
    final cli = CognitiveLoadIndex();

    // Buffer fill (2 s) + baseline capture (15 s), with margin.
    gen.snapLoad(0.15);
    _run(gen, engine, cli, 25);
    expect(cli.isCalibrated, isTrue,
        reason: 'baseline should have landed within 25 s');

    final calm = _run(gen, engine, cli, 15);

    gen.snapLoad(0.90);
    _run(gen, engine, cli, 15); // let the tracker and EMA settle
    final strained = _run(gen, engine, cli, 15);

    // The headline demo behaviour: the number has to actually travel.
    // If someone retunes kScale/kOffset into a flat line, this fails loudly.
    expect(strained - calm, greaterThan(25.0),
        reason: 'calm=$calm strained=$strained');

    expect(calm, inInclusiveRange(15.0, 40.0), reason: 'calm=$calm');
    expect(strained, greaterThan(70.0), reason: 'strained=$strained');
    expect(cli.state, LoadState.strain);
  });

  test('recovery brings the index back down and clears strain', () {
    final gen = ScenarioEEGGenerator(seed: 7, tauSeconds: 0.5);
    final engine = DartDspEngine();
    final cli = CognitiveLoadIndex();

    gen.snapLoad(0.15);
    _run(gen, engine, cli, 25);

    gen.snapLoad(0.90);
    _run(gen, engine, cli, 25);
    expect(cli.state, LoadState.strain);

    // This is what the reset protocol does to the simulation.
    gen.snapLoad(0.15);
    final recovered = _run(gen, engine, cli, 25);

    expect(recovered, lessThan(50.0), reason: 'recovered=$recovered');
    expect(cli.state, LoadState.steady);
  });
}
