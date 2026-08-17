import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

/// Type definition for the C FFI functions
typedef SignalFilterCreateC = Pointer<Void> Function(Int32 windowSize);
typedef SignalFilterCreateDart = Pointer<Void> Function(int windowSize);

typedef SignalFilterProcessC = Float Function(Pointer<Void> handle, Float value);
typedef SignalFilterProcessDart = double Function(Pointer<Void> handle, double value);

typedef SignalFilterResetC = Void Function(Pointer<Void> handle);
typedef SignalFilterResetDart = void Function(Pointer<Void> handle);

typedef SignalFilterDestroyC = Void Function(Pointer<Void> handle);
typedef SignalFilterDestroyDart = void Function(Pointer<Void> handle);

typedef SignalFilterGetWindowSizeC = Int32 Function(Pointer<Void> handle);
typedef SignalFilterGetWindowSizeDart = int Function(Pointer<Void> handle);

/// Dart wrapper for the C++ signal filter
class SignalProcessor {
  late final DynamicLibrary _lib;
  late final SignalFilterCreateDart _create;
  late final SignalFilterProcessDart _process;
  late final SignalFilterResetDart _reset;
  late final SignalFilterDestroyDart _destroy;
  late final SignalFilterGetWindowSizeDart _getWindowSize;

  Pointer<Void>? _filterHandle;
  bool _initialized = false;

  SignalProcessor() {
    _loadLibrary();
  }

  void _loadLibrary() {
    try {
      if (Platform.isAndroid) {
        _lib = DynamicLibrary.open('libkore_signal.so');
      } else if (Platform.isIOS) {
        _lib = DynamicLibrary.process();
      } else if (Platform.isWindows) {
        _lib = DynamicLibrary.open('kore_signal.dll');
      } else if (Platform.isLinux) {
        _lib = DynamicLibrary.open('libkore_signal.so');
      } else if (Platform.isMacOS) {
        _lib = DynamicLibrary.open('libkore_signal.dylib');
      } else {
        throw UnsupportedError('Platform not supported');
      }

      _create = _lib.lookupFunction<SignalFilterCreateC, SignalFilterCreateDart>(
        'signal_filter_create',
      );
      _process = _lib.lookupFunction<SignalFilterProcessC, SignalFilterProcessDart>(
        'signal_filter_process',
      );
      _reset = _lib.lookupFunction<SignalFilterResetC, SignalFilterResetDart>(
        'signal_filter_reset',
      );
      _destroy = _lib.lookupFunction<SignalFilterDestroyC, SignalFilterDestroyDart>(
        'signal_filter_destroy',
      );
      _getWindowSize = _lib.lookupFunction<SignalFilterGetWindowSizeC, SignalFilterGetWindowSizeDart>(
        'signal_filter_get_window_size',
      );
    } catch (e) {
      throw Exception('Failed to load native library: $e');
    }
  }

  /// Initialize the signal filter with a window size for moving average
  void initialize(int windowSize) {
    if (_initialized && _filterHandle != null) {
      dispose();
    }

    try {
      _filterHandle = _create(windowSize);
      if (_filterHandle == nullptr) {
        throw Exception('Failed to create signal filter');
      }
      _initialized = true;
    } catch (e) {
      throw Exception('Failed to initialize signal processor: $e');
    }
  }

  /// Process a single sample through the filter
  double process(double value) {
    if (!_initialized || _filterHandle == null) {
      throw Exception('Signal processor not initialized. Call initialize() first.');
    }

    try {
      return _process(_filterHandle!, value);
    } catch (e) {
      throw Exception('Error processing sample: $e');
    }
  }

  /// Reset filter state
  void reset() {
    if (_filterHandle != null) {
      try {
        _reset(_filterHandle!);
      } catch (e) {
        throw Exception('Error resetting filter: $e');
      }
    }
  }

  /// Get the window size of the filter
  int getWindowSize() {
    if (_filterHandle == null) {
      return -1;
    }

    try {
      return _getWindowSize(_filterHandle!);
    } catch (e) {
      throw Exception('Error getting window size: $e');
    }
  }

  /// Clean up and free native resources
  void dispose() {
    if (_filterHandle != null) {
      try {
        _destroy(_filterHandle!);
        _filterHandle = null;
        _initialized = false;
      } catch (e) {
        throw Exception('Error disposing signal processor: $e');
      }
    }
  }

  bool get isInitialized => _initialized && _filterHandle != null;
}
