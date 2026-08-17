import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'dart:async';
import 'eeg_data_stream.dart';

/// Service wrapper for BLE operations
/// Manages connection, scanning, and data subscription for EEG wearable
class BLEService {
  static const String _dummyDeviceName = 'KORE_EEG_DUMMY';
  static const Duration _scanTimeout = Duration(seconds: 5);
  static const Duration _connectionTimeout = Duration(seconds: 10);

  final flutterReactiveBle = FlutterReactiveBle();

  DiscoveredDevice? _connectedDevice;
  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  StreamSubscription<List<int>>? _eegSubscription;

  final StreamController<EEGSample> _eegDataController =
      StreamController<EEGSample>.broadcast();

  final StreamController<bool> _connectionStateController =
      StreamController<bool>.broadcast();

  // For mock mode (when real BLE unavailable)
  final EEGDataStream _mockDataStream = EEGDataStream(channelCount: 2);
  Timer? _mockDataTimer;
  bool _useMockMode = false;

  /// Get the EEG data stream
  Stream<EEGSample> get eegDataStream => _eegDataController.stream;

  /// Get connection state stream
  Stream<bool> get connectionStateStream => _connectionStateController.stream;

  /// Check if using mock mode (simulated data)
  bool get isMockMode => _useMockMode;

  /// Scan for EEG devices
  Future<List<DiscoveredDevice>> scanForDevices() async {
    try {
      final devices = <DiscoveredDevice>[];

      // Try to scan using real BLE first
      try {
        await flutterReactiveBle.startScan(
          withServices: [],
        );

        // Listen for scan results
        await for (final device
            in flutterReactiveBle.scanStream.take(50)) {
          if (device.name.contains(_dummyDeviceName)) {
            devices.add(device);
          }
          if (devices.length >= 1) {
            break; // Stop after finding first matching device
          }
        }

        await flutterReactiveBle.stopScan();
      } catch (e) {
        // Real BLE failed, fall back to mock mode
        print('BLE scan failed: $e. Using mock mode.');
        _useMockMode = true;
        devices.add(DiscoveredDevice(
          id: 'mock_kore_eeg',
          name: _dummyDeviceName,
          serviceUuids: [],
          connectable: true,
          rssi: -50,
        ));
      }

      return devices;
    } catch (e) {
      print('Error scanning for devices: $e');
      return [];
    }
  }

  /// Connect to a specific device
  Future<bool> connect(String deviceId) async {
    try {
      if (_useMockMode) {
        // Mock mode: simulate connection
        _mockDataStream.reset();
        _startMockDataStream();
        _connectionStateController.add(true);
        return true;
      }

      // Real BLE mode
      final connection = flutterReactiveBle.connectToAdvertisingDevice(
        id: deviceId,
        prescanDuration: _scanTimeout,
        withServices: [],
        servicesWithCharacteristicsToDiscover: {},
        connectionTimeout: _connectionTimeout,
      );

      _connectionSubscription?.cancel();
      _connectionSubscription = connection.listen(
        (connectionState) {
          if (connectionState.connectionState ==
              DeviceConnectionState.connected) {
            _connectedDevice = connectionState.discoveredDevice;
            _connectionStateController.add(true);
            _subscribeToEEGData();
          } else if (connectionState.connectionState ==
              DeviceConnectionState.disconnected) {
            _connectionStateController.add(false);
            _eegSubscription?.cancel();
          }
        },
        onError: (error) {
          print('Connection error: $error');
          _connectionStateController.add(false);
        },
      );

      return true;
    } catch (e) {
      print('Error connecting to device: $e');
      _connectionStateController.add(false);
      return false;
    }
  }

  /// Subscribe to EEG data from connected device
  Future<void> _subscribeToEEGData() async {
    if (_useMockMode || _connectedDevice == null) {
      return;
    }

    try {
      // For real BLE, subscribe to characteristic
      // Placeholder: implement actual UUID-based subscription
      _eegSubscription?.cancel();
    } catch (e) {
      print('Error subscribing to EEG data: $e');
    }
  }

  /// Start mock data stream (for testing without hardware)
  void _startMockDataStream() {
    _mockDataTimer?.cancel();

    _mockDataTimer = Timer.periodic(
      Duration(milliseconds: _mockDataStream.getSamplingIntervalMs()),
      (_) {
        final sample = _mockDataStream.getNextSample();
        _eegDataController.add(sample);
      },
    );
  }

  /// Disconnect from device
  Future<void> disconnect() async {
    try {
      _mockDataTimer?.cancel();
      _connectionSubscription?.cancel();
      _eegSubscription?.cancel();
      _connectedDevice = null;
      _connectionStateController.add(false);

      if (!_useMockMode) {
        await flutterReactiveBle.deinitialize();
      }
    } catch (e) {
      print('Error disconnecting: $e');
    }
  }

  /// Get connected device
  DiscoveredDevice? get connectedDevice => _connectedDevice;

  /// Is currently connected
  bool get isConnected =>
      _useMockMode ? (_mockDataTimer?.isActive ?? false) : _connectedDevice != null;

  /// Clean up resources
  void dispose() {
    _mockDataTimer?.cancel();
    _connectionSubscription?.cancel();
    _eegSubscription?.cancel();
    _eegDataController.close();
    _connectionStateController.close();
  }
}
