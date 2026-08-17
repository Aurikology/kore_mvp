#include "signal_filter.h"

// C interface for FFI
extern "C" {

// Create a new signal filter instance
// Returns opaque pointer to SignalFilter object
void* signal_filter_create(int window_size) {
  try {
    return new kore::SignalFilter(window_size);
  } catch (...) {
    return nullptr;
  }
}

// Process a single sample through the filter
// Returns filtered value or -1.0 on error
float signal_filter_process(void* handle, float value) {
  if (handle == nullptr) {
    return -1.0f;
  }
  try {
    kore::SignalFilter* filter = static_cast<kore::SignalFilter*>(handle);
    return filter->ProcessSample(value);
  } catch (...) {
    return -1.0f;
  }
}

// Reset filter to initial state
void signal_filter_reset(void* handle) {
  if (handle == nullptr) {
    return;
  }
  try {
    kore::SignalFilter* filter = static_cast<kore::SignalFilter*>(handle);
    filter->Reset();
  } catch (...) {
    // Silently fail
  }
}

// Destroy filter instance and free memory
void signal_filter_destroy(void* handle) {
  if (handle == nullptr) {
    return;
  }
  try {
    kore::SignalFilter* filter = static_cast<kore::SignalFilter*>(handle);
    delete filter;
  } catch (...) {
    // Silently fail
  }
}

// Get window size of filter
int signal_filter_get_window_size(void* handle) {
  if (handle == nullptr) {
    return -1;
  }
  try {
    kore::SignalFilter* filter = static_cast<kore::SignalFilter*>(handle);
    return filter->GetWindowSize();
  } catch (...) {
    return -1;
  }
}

}  // extern "C"
