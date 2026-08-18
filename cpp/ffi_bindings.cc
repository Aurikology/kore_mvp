#include "kore_dsp.h"

#include <new>

// C ABI for dart:ffi.
//
// Every function is both `extern "C"` (no name mangling) and KORE_EXPORT
// (actually placed in the export table). On MSVC the second half is not
// optional - see the note in kore_dsp.h.
//
// Exceptions must never cross this boundary: unwinding into Dart is
// undefined behaviour, so each entry point swallows and returns a sentinel.

extern "C" {

// Bin ranges are passed in rather than hardcoded so DspConfig on the Dart
// side stays the single source of truth for the analysis geometry.
KORE_EXPORT void* kore_dsp_create(double fs, int window, int hop,
                                  int theta_lo, int theta_hi,
                                  int alpha_lo, int alpha_hi) {
  if (window <= 0 || hop <= 0) return nullptr;
  if (theta_lo < 0 || theta_hi < theta_lo) return nullptr;
  if (alpha_lo < 0 || alpha_hi < alpha_lo) return nullptr;
  if (theta_hi >= window || alpha_hi >= window) return nullptr;
  try {
    return new kore::KoreDsp(fs, window, hop, theta_lo, theta_hi,
                             alpha_lo, alpha_hi);
  } catch (...) {
    return nullptr;
  }
}

// Returns 1 if at least one analysis frame completed during this block.
KORE_EXPORT int kore_dsp_push_block(void* handle, const double* in, int n) {
  if (handle == nullptr) return -1;
  try {
    return static_cast<kore::KoreDsp*>(handle)->PushBlock(in, n);
  } catch (...) {
    return -1;
  }
}

KORE_EXPORT int kore_dsp_frame_ready(void* handle) {
  if (handle == nullptr) return 0;
  try {
    return static_cast<kore::KoreDsp*>(handle)->FrameReady();
  } catch (...) {
    return 0;
  }
}

// out3 receives {theta, alpha, total} in uV^2.
KORE_EXPORT void kore_dsp_read_frame(void* handle, double* out3) {
  if (handle == nullptr || out3 == nullptr) return;
  try {
    static_cast<kore::KoreDsp*>(handle)->ReadFrame(out3);
  } catch (...) {
  }
}

KORE_EXPORT double kore_dsp_last_filtered(void* handle) {
  if (handle == nullptr) return 0.0;
  try {
    return static_cast<kore::KoreDsp*>(handle)->last_filtered();
  } catch (...) {
    return 0.0;
  }
}

KORE_EXPORT void kore_dsp_reset(void* handle) {
  if (handle == nullptr) return;
  try {
    static_cast<kore::KoreDsp*>(handle)->Reset();
  } catch (...) {
  }
}

KORE_EXPORT void kore_dsp_destroy(void* handle) {
  if (handle == nullptr) return;
  delete static_cast<kore::KoreDsp*>(handle);
}

// Cheap liveness probe, used by the Dart side to confirm the library both
// loaded *and* resolved symbols before it commits to the native path.
KORE_EXPORT int kore_dsp_abi_version() { return 1; }

}  // extern "C"
