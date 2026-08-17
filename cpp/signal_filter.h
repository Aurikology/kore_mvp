#ifndef KORE_SIGNAL_FILTER_H_
#define KORE_SIGNAL_FILTER_H_

#include <vector>
#include <cstring>

namespace kore {

class SignalFilter {
 public:
  // Constructor with window size for moving average
  explicit SignalFilter(int window_size);

  // Process a single sample through the moving average filter
  float ProcessSample(float value);

  // Reset filter state
  void Reset();

  // Get current buffer size
  int GetWindowSize() const { return window_size_; }

  // Destructor
  ~SignalFilter();

 private:
  int window_size_;
  std::vector<float> buffer_;
  int buffer_index_;
  float sum_;
};

}  // namespace kore

#endif  // KORE_SIGNAL_FILTER_H_
