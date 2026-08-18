// Offline probe for tuning the Cognitive Load Index.
//
// Sweeps the scenario generator across load levels, runs the real DSP chain,
// and prints the band powers and resulting index. Use this to retune
// CognitiveLoadIndex.kScale / kOffset without launching the app.
//
//   dart run tool/cli_probe.dart

// This is a console tool, not app code - printing is the whole point.
// ignore_for_file: avoid_print

import 'package:kore/dsp/cognitive_load_index.dart';
import 'package:kore/dsp/dart_dsp_engine.dart';
import 'package:kore/dsp/dsp_engine.dart';
import 'package:kore/sources/scenario_eeg_generator.dart';

({double cli, double theta, double alpha}) measure(
  ScenarioEEGGenerator gen,
  DartDspEngine engine,
  CognitiveLoadIndex cli,
  double seconds,
) {
  final blocks = (seconds * DspConfig.framesPerSecond).round();
  var sumCli = 0.0, sumTheta = 0.0, sumAlpha = 0.0;
  var n = 0;

  for (var b = 0; b < blocks; b++) {
    engine.pushBlock(
        List<double>.generate(DspConfig.hopSize, (_) => gen.nextSampleMicrovolts()));
    final frame = engine.takeFrame();
    if (frame == null) continue;
    cli.update(frame);
    if (cli.isCalibrated) {
      sumCli += cli.value;
      sumTheta += frame.theta;
      sumAlpha += frame.alpha;
      n++;
    }
  }
  return n == 0
      ? (cli: double.nan, theta: double.nan, alpha: double.nan)
      : (cli: sumCli / n, theta: sumTheta / n, alpha: sumAlpha / n);
}

void main() {
  final gen = ScenarioEEGGenerator(seed: 1, tauSeconds: 0.5);
  final engine = DartDspEngine();
  final cli = CognitiveLoadIndex();

  // Calibrate at rest.
  gen.snapLoad(0.15);
  measure(gen, engine, cli, 25);
  print('baseline mu = ${cli.baseline.toStringAsFixed(3)}  '
      '(kScale=${CognitiveLoadIndex.kScale}, kOffset=${CognitiveLoadIndex.kOffset})');
  print('');
  print(' load |   theta |   alpha |  r-mu |  CLI');
  print('------+---------+---------+-------+------');

  for (final load in [0.15, 0.35, 0.50, 0.75, 0.90]) {
    gen.snapLoad(load);
    measure(gen, engine, cli, 12); // settle
    final m = measure(gen, engine, cli, 12);
    print(' ${load.toStringAsFixed(2)} | '
        '${m.theta.toStringAsFixed(0).padLeft(7)} | '
        '${m.alpha.toStringAsFixed(0).padLeft(7)} | '
        '${cli.deviation.toStringAsFixed(2).padLeft(5)} | '
        '${m.cli.toStringAsFixed(1).padLeft(5)}');
  }
}
