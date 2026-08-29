import 'package:flutter/foundation.dart';

import '../services/kore_ble.dart';
import 'ble_eeg_source.dart';
import 'eeg_source.dart';
import 'simulated_eeg_source.dart';

/// Builds the best available [EegSource].
///
/// `createDspEngine()` in a different costume, and deliberately so: try the
/// platform, fall back to something that works, and let a missing capability
/// cost a log line rather than the app. A build with no BLE host - every
/// desktop build, and any Android build whose host is not installed - gets the
/// simulator, and nothing downstream carries a conditional about it.
///
/// The difference from the engine factory is what the fallback *means*. A
/// missing native DSP costs speed and nothing else, because the Dart engine
/// runs the identical algorithm. A missing radio costs the measurement: the
/// simulator is a model of a person, not a person. So the fallback is never
/// silent - [EegSource.label] says "Simulated signal", the dashboard badge
/// says so on every surface, and [SimulatedEegSource.demo] being non-null is
/// what makes the demo panel appear at all.
EegSource createEegSource() {
  final ble = createKoreBle();
  if (!ble.isSupported) {
    // Not an error and not worth a warning: this is every desktop build.
    ble.dispose();
    return SimulatedEegSource();
  }

  try {
    final source = BleEegSource(ble: ble);
    debugPrint('KORE: using ${source.label}');
    return source;
  } catch (e) {
    debugPrint('KORE: BLE source unavailable ($e); falling back to simulated');
    ble.dispose();
    return SimulatedEegSource();
  }
}
