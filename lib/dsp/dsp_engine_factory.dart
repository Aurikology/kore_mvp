import 'package:flutter/foundation.dart';

import 'dart_dsp_engine.dart';
import 'dsp_engine.dart';
import 'native_dsp_engine.dart';

/// Builds the best available [DspEngine].
///
/// The rule this enforces: **no FFI object is ever constructed outside a
/// try/catch.** The app previously created its FFI wrapper in initState with
/// the catch one line too late, so a missing native library red-screened the
/// app on launch. Here a missing or broken DLL costs a debug line and nothing
/// else - the pure-Dart engine runs the identical algorithm, and the only
/// visible difference is the backend label.
///
/// [config] is the rate the engine is tuned to. It defaults to
/// [DspConfig.nominal] so a caller with no source in hand gets the published
/// behaviour; a session with a device attached passes the rate that device is
/// measured to be running at.
DspEngine createDspEngine({DspConfig config = DspConfig.nominal}) {
  try {
    final engine = NativeDspEngine(config: config);
    debugPrint('KORE: using ${engine.backendLabel} at '
        '${config.sampleRateHz.toStringAsFixed(2)} Hz');
    return engine;
  } catch (e) {
    debugPrint('KORE: native DSP unavailable ($e); falling back to Dart');
    return DartDspEngine(config: config);
  }
}
