#include "signal_filter.h"
#include <cmath>

namespace kore {

SignalFilter::SignalFilter(int window_size)
    : window_size_(window_size), buffer_index_(0), sum_(0.0f) {
  if (window_size_ < 1) {
    window_size_ = 1;
  }
  buffer_.resize(window_size_, 0.0f);
}

float SignalFilter::ProcessSample(float value) {
  // Remove old value from sum
  sum_ -= buffer_[buffer_index_];

  // Add new value
  buffer_[buffer_index_] = value;
  sum_ += value;

  // Move to next position (circular buffer)
  buffer_index_ = (buffer_index_ + 1) % window_size_;

  // Return moving average
  return sum_ / window_size_;
}

void SignalFilter::Reset() {
  buffer_index_ = 0;
  sum_ = 0.0f;
  std::fill(buffer_.begin(), buffer_.end(), 0.0f);
}

SignalFilter::~SignalFilter() = default;

}  // namespace kore
