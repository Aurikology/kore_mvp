import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'band_powers.dart';
import 'dsp_engine.dart';

// C signatures. The native side mirrors DartDspEngine sample for sample, in
// double precision, so the two agree to within float rounding.
typedef _CreateC = Pointer<Void> Function(
    Double fs, Int32 window, Int32 hop, Int32 tLo, Int32 tHi, Int32 aLo, Int32 aHi);
typedef _CreateD = Pointer<Void> Function(
    double fs, int window, int hop, int tLo, int tHi, int aLo, int aHi);

typedef _PushBlockC = Int32 Function(Pointer<Void>, Pointer<Double>, Int32);
typedef _PushBlockD = int Function(Pointer<Void>, Pointer<Double>, int);

typedef _IntHandleC = Int32 Function(Pointer<Void>);
typedef _IntHandleD = int Function(Pointer<Void>);

typedef _ReadFrameC = Void Function(Pointer<Void>, Pointer<Double>);
typedef _ReadFrameD = void Function(Pointer<Void>, Pointer<Double>);

typedef _DoubleHandleC = Double Function(Pointer<Void>);
typedef _DoubleHandleD = double Function(Pointer<Void>);

typedef _VoidHandleC = Void Function(Pointer<Void>);
typedef _VoidHandleD = void Function(Pointer<Void>);

typedef _AbiC = Int32 Function();
typedef _AbiD = int Function();

/// C++/FFI implementation of the KORE signal chain.
///
/// The constructor throws if the library is missing, its symbols cannot be
/// resolved, or the ABI version does not match. [createDspEngine] catches all
/// three and falls back to the Dart engine.
///
/// The symbol-lookup case is the one worth naming: on Windows `extern "C"`
/// controls name mangling, not export. A DLL built without
/// `__declspec(dllexport)` opens *successfully* and only fails later at
/// lookupFunction, so a load-succeeded check proves nothing on its own.
class NativeDspEngine implements DspEngine {
  static const String libraryName = 'kore_signal';
  static const int expectedAbiVersion = 1;

  /// Largest block accepted in one FFI call; longer blocks are chunked.
  static const int _maxBlockSamples = 4096;

  final DynamicLibrary _lib;
  late final _CreateD _create;
  late final _PushBlockD _pushBlock;
  late final _IntHandleD _frameReady;
  late final _ReadFrameD _readFrame;
  late final _DoubleHandleD _lastFiltered;
  late final _VoidHandleD _reset;
  late final _VoidHandleD _destroy;

  late final Pointer<Void> _handle;
  late final Pointer<Double> _inBuffer;
  late final Pointer<Double> _outBuffer;

  int _frameIndex = 0;
  BandPowers? _pending;
  bool _disposed = false;

  @override
  final DspConfig config;

  NativeDspEngine({String? libraryPath, this.config = DspConfig.nominal})
      : _lib = _open(libraryPath) {
    final abi = _lib.lookupFunction<_AbiC, _AbiD>('kore_dsp_abi_version');
    final version = abi();
    if (version != expectedAbiVersion) {
      throw StateError(
          'kore_signal ABI mismatch: got $version, expected $expectedAbiVersion');
    }

    _create = _lib.lookupFunction<_CreateC, _CreateD>('kore_dsp_create');
    _pushBlock =
        _lib.lookupFunction<_PushBlockC, _PushBlockD>('kore_dsp_push_block');
    _frameReady =
        _lib.lookupFunction<_IntHandleC, _IntHandleD>('kore_dsp_frame_ready');
    _readFrame =
        _lib.lookupFunction<_ReadFrameC, _ReadFrameD>('kore_dsp_read_frame');
    _lastFiltered = _lib.lookupFunction<_DoubleHandleC, _DoubleHandleD>(
        'kore_dsp_last_filtered');
    _reset = _lib.lookupFunction<_VoidHandleC, _VoidHandleD>('kore_dsp_reset');
    _destroy =
        _lib.lookupFunction<_VoidHandleC, _VoidHandleD>('kore_dsp_destroy');

    // Geometry and rate both come from DspConfig so the Dart side stays the
    // single source of truth. The rate was always a parameter of
    // kore_dsp_create - the C++ port builds its DC blocker and its notch from
    // whatever it is handed - so accommodating a real crystal needed nothing
    // on the native side but for Dart to stop passing it a constant.
    _handle = _create(
      config.sampleRateHz,
      DspConfig.windowSize,
      DspConfig.hopSize,
      DspConfig.thetaBinLo,
      DspConfig.thetaBinHi,
      DspConfig.alphaBinLo,
      DspConfig.alphaBinHi,
    );
    if (_handle == nullptr) {
      throw StateError('kore_dsp_create returned null');
    }

    _inBuffer = calloc<Double>(_maxBlockSamples);
    _outBuffer = calloc<Double>(3);
  }

  static DynamicLibrary _open(String? explicitPath) {
    if (explicitPath != null) return DynamicLibrary.open(explicitPath);
    // A bare filename resolves through LoadLibraryW's search order, which
    // starts at the executable's directory - so the DLL must sit next to
    // kore.exe, which windows/CMakeLists.txt installs it to.
    if (Platform.isWindows) return DynamicLibrary.open('$libraryName.dll');
    if (Platform.isMacOS) return DynamicLibrary.open('lib$libraryName.dylib');
    if (Platform.isIOS) return DynamicLibrary.process();
    return DynamicLibrary.open('lib$libraryName.so');
  }

  @override
  String get backendLabel => 'Native DSP (C++)';

  @override
  double get lastFiltered => _disposed ? 0 : _lastFiltered(_handle);

  @override
  void pushBlock(List<double> microvolts) {
    if (_disposed || microvolts.isEmpty) return;

    var offset = 0;
    while (offset < microvolts.length) {
      final n = (microvolts.length - offset).clamp(0, _maxBlockSamples);
      for (var i = 0; i < n; i++) {
        _inBuffer[i] = microvolts[offset + i];
      }
      _pushBlock(_handle, _inBuffer, n);
      offset += n;

      // Drain inside the loop: a block longer than the hop can complete more
      // than one frame, and the native side keeps only the newest.
      if (_frameReady(_handle) != 0) {
        _readFrame(_handle, _outBuffer);
        _pending = BandPowers(
          theta: _outBuffer[0],
          alpha: _outBuffer[1],
          total: _outBuffer[2],
          frameIndex: _frameIndex++,
        );
      }
    }
  }

  @override
  BandPowers? takeFrame() {
    final f = _pending;
    _pending = null;
    return f;
  }

  @override
  void reset() {
    if (_disposed) return;
    _reset(_handle);
    _pending = null;
    _frameIndex = 0;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _destroy(_handle);
    calloc.free(_inBuffer);
    calloc.free(_outBuffer);
  }
}
