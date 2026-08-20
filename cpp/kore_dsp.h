#ifndef KORE_DSP_H_
#define KORE_DSP_H_

#include <vector>

// Symbol export.
//
// On Windows, `extern "C"` controls *name mangling*, not *export*. Without
// __declspec(dllexport) the DLL builds with an empty export table,
// DynamicLibrary.open() succeeds, and the failure only surfaces later at
// lookupFunction. Both halves are needed.
#if defined(_WIN32)
#define KORE_EXPORT __declspec(dllexport)
#else
#define KORE_EXPORT __attribute__((visibility("default")))
#endif

namespace kore {

// Direct-form-I biquad. Coefficients are pre-normalised by a0.
class Biquad {
 public:
  Biquad() = default;

  // RBJ cookbook notch at f0 Hz with quality factor q.
  static Biquad Notch(double fs, double f0, double q);

  double Process(double x);
  void Reset();

 private:
  double b0_ = 1, b1_ = 0, b2_ = 0, a1_ = 0, a2_ = 0;
  double x1_ = 0, x2_ = 0, y1_ = 0, y2_ = 0;
};

// One-pole DC blocker: y[n] = x[n] - x[n-1] + R*y[n-1].
class DcBlocker {
 public:
  explicit DcBlocker(double fs = 256.0, double cutoff_hz = 0.5);

  double Process(double x);
  void Reset();

 private:
  double r_;
  double x1_ = 0, y1_ = 0;
};

// Streaming band-power analyser.
//
// Mirrors DartDspEngine sample for sample. Everything is double precision
// specifically so the two implementations agree to within float rounding -
// a float32 core would drift through the Goertzel accumulation and turn
// parity testing into guesswork.
class KoreDsp {
 public:
  KoreDsp(double fs, int window, int hop,
          int theta_lo, int theta_hi, int alpha_lo, int alpha_hi);

  // Feed n samples in microvolts. Returns 1 if a new frame completed.
  int PushBlock(const double* in, int n);

  int FrameReady() const { return frame_ready_ ? 1 : 0; }

  // Writes {theta, alpha, total} in uV^2 and clears the ready flag.
  void ReadFrame(double* out3);

  double last_filtered() const { return last_filtered_; }

  void Reset();

 private:
  void ComputeFrame();
  double GoertzelMagSq(int k) const;

  const int n_;
  const int hop_;
  const int theta_lo_, theta_hi_, alpha_lo_, alpha_hi_;

  DcBlocker dc_;
  Biquad notch_;

  std::vector<double> window_;   // periodic Hann
  std::vector<double> ring_;
  std::vector<double> scratch_;  // time-ordered copy for the Goertzel bank

  double sum_w2_ = 0;
  int write_index_ = 0;
  int samples_seen_ = 0;
  int samples_since_frame_ = 0;

  bool frame_ready_ = false;
  double theta_ = 0, alpha_ = 0, total_ = 0;
  double last_filtered_ = 0;
};

}  // namespace kore

#endif  // KORE_DSP_H_
