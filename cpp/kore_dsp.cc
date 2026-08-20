#include "kore_dsp.h"

#include <cmath>

namespace kore {

namespace {
constexpr double kPi = 3.14159265358979323846;
}  // namespace

// --- Biquad -------------------------------------------------------------

Biquad Biquad::Notch(double fs, double f0, double q) {
  const double w0 = 2.0 * kPi * f0 / fs;
  const double cos_w0 = std::cos(w0);
  const double sin_w0 = std::sin(w0);
  const double alpha = sin_w0 / (2.0 * q);
  const double a0 = 1.0 + alpha;

  Biquad b;
  b.b0_ = 1.0 / a0;
  b.b1_ = -2.0 * cos_w0 / a0;
  b.b2_ = 1.0 / a0;
  b.a1_ = -2.0 * cos_w0 / a0;
  b.a2_ = (1.0 - alpha) / a0;
  return b;
}

double Biquad::Process(double x) {
  const double y = b0_ * x + b1_ * x1_ + b2_ * x2_ - a1_ * y1_ - a2_ * y2_;
  x2_ = x1_;
  x1_ = x;
  y2_ = y1_;
  y1_ = y;
  return y;
}

void Biquad::Reset() { x1_ = x2_ = y1_ = y2_ = 0; }

// --- DcBlocker ----------------------------------------------------------

DcBlocker::DcBlocker(double fs, double cutoff_hz)
    : r_(1.0 - 2.0 * kPi * cutoff_hz / fs) {}

double DcBlocker::Process(double x) {
  const double y = x - x1_ + r_ * y1_;
  x1_ = x;
  y1_ = y;
  return y;
}

void DcBlocker::Reset() { x1_ = y1_ = 0; }

// --- KoreDsp ------------------------------------------------------------

KoreDsp::KoreDsp(double fs, int window, int hop,
                 int theta_lo, int theta_hi, int alpha_lo, int alpha_hi)
    : n_(window),
      hop_(hop),
      theta_lo_(theta_lo),
      theta_hi_(theta_hi),
      alpha_lo_(alpha_lo),
      alpha_hi_(alpha_hi),
      dc_(fs, 0.5),
      notch_(Biquad::Notch(fs, 60.0, 20.0)),
      window_(static_cast<size_t>(window)),
      ring_(static_cast<size_t>(window), 0.0),
      scratch_(static_cast<size_t>(window), 0.0) {
  // Periodic (DFT-even) Hann: dividing by N, not N-1. That is what makes
  // sum(w^2) exactly 3N/8 and keeps the power normalisation an exact
  // constant rather than an empirical fudge.
  for (int i = 0; i < n_; ++i) {
    window_[static_cast<size_t>(i)] =
        0.5 * (1.0 - std::cos(2.0 * kPi * i / n_));
  }
  sum_w2_ = 3.0 * n_ / 8.0;
}

int KoreDsp::PushBlock(const double* in, int n) {
  if (in == nullptr || n <= 0) return 0;

  int produced = 0;
  for (int i = 0; i < n; ++i) {
    const double filtered = notch_.Process(dc_.Process(in[i]));
    last_filtered_ = filtered;

    ring_[static_cast<size_t>(write_index_)] = filtered;
    write_index_ = (write_index_ + 1) % n_;
    if (samples_seen_ < n_) ++samples_seen_;
    ++samples_since_frame_;

    if (samples_seen_ >= n_ && samples_since_frame_ >= hop_) {
      samples_since_frame_ = 0;
      ComputeFrame();
      produced = 1;
    }
  }
  return produced;
}

double KoreDsp::GoertzelMagSq(int k) const {
  const double coeff = 2.0 * std::cos(2.0 * kPi * k / n_);
  double s1 = 0, s2 = 0;
  for (int i = 0; i < n_; ++i) {
    const double s0 = scratch_[static_cast<size_t>(i)] *
                          window_[static_cast<size_t>(i)] +
                      coeff * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  return s1 * s1 + s2 * s2 - coeff * s1 * s2;
}

void KoreDsp::ComputeFrame() {
  // Unwrap the ring into time order; once full, write_index_ is the oldest.
  for (int i = 0; i < n_; ++i) {
    scratch_[static_cast<size_t>(i)] =
        ring_[static_cast<size_t>((write_index_ + i) % n_)];
  }

  // One-sided, window-corrected: a pure sine of amplitude A reports A^2/2.
  const double scale = 2.0 / (n_ * sum_w2_);

  double theta = 0;
  for (int k = theta_lo_; k <= theta_hi_; ++k) theta += GoertzelMagSq(k);

  double alpha = 0;
  for (int k = alpha_lo_; k <= alpha_hi_; ++k) alpha += GoertzelMagSq(k);

  theta_ = theta * scale;
  alpha_ = alpha * scale;
  total_ = (theta + alpha) * scale;
  frame_ready_ = true;
}

void KoreDsp::ReadFrame(double* out3) {
  if (out3 == nullptr) return;
  out3[0] = theta_;
  out3[1] = alpha_;
  out3[2] = total_;
  frame_ready_ = false;
}

void KoreDsp::Reset() {
  dc_.Reset();
  notch_.Reset();
  for (auto& v : ring_) v = 0.0;
  write_index_ = 0;
  samples_seen_ = 0;
  samples_since_frame_ = 0;
  frame_ready_ = false;
  theta_ = alpha_ = total_ = 0;
  last_filtered_ = 0;
}

}  // namespace kore
