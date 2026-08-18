import 'dart:ffi';
import 'dart:io';

import 'band_powers.dart';
import 'dsp_engine.dart';

/// C++/FFI implementation of the KORE signal chain.
///
/// Not built yet - [createDspEngine] catches the constructor throw and falls
/// back to [DartDspEngine], which implements the identical algorithm. The
/// fallback is not a degraded mode; it is the reference implementation, and
/// the native path will be validated against it by a parity test.
///
/// When wiring this up, note the Windows trap: `extern "C"` controls name
/// mangling, not export. Without `__declspec(dllexport)` the DLL builds with
/// an empty export table, [DynamicLibrary.open] *succeeds*, and the failure
/// only surfaces at `lookupFunction`. Both failure modes have to be caught.
class NativeDspEngine implements DspEngine {
  static const String libraryName = 'kore_signal';

  NativeDspEngine() {
    throw UnsupportedError(
      'Native DSP is not built yet - see cpp/ and windows/CMakeLists.txt.',
    );
  }

  /// Platform-correct library handle. A bare filename resolves through the
  /// standard search order, which starts at the executable's directory - so
  /// the DLL must be installed next to kore.exe, not merely somewhere on disk.
  static DynamicLibrary openLibrary() {
    if (Platform.isWindows) return DynamicLibrary.open('$libraryName.dll');
    if (Platform.isMacOS) return DynamicLibrary.open('lib$libraryName.dylib');
    if (Platform.isIOS) return DynamicLibrary.process();
    return DynamicLibrary.open('lib$libraryName.so');
  }

  @override
  String get backendLabel => 'Native DSP (C++)';

  @override
  double get lastFiltered => throw UnimplementedError();

  @override
  void pushBlock(List<double> microvolts) => throw UnimplementedError();

  @override
  BandPowers? takeFrame() => throw UnimplementedError();

  @override
  void reset() => throw UnimplementedError();

  @override
  void dispose() {}
}
