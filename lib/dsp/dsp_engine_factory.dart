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
DspEngine createDspEngine() {
  try {
    final engine = NativeDspEngine();
    debugPrint('KORE: using ${engine.backendLabel}');
    return engine;
  } catch (e) {
    debugPrint('KORE: native DSP unavailable ($e); falling back to Dart');
    return DartDspEngine();
  }
}
