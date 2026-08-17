import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'theme.dart';
import 'services/ble_service.dart';
import 'services/signal_processor_service.dart';
import 'services/eeg_data_stream.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await GoogleFonts.pendingFonts([
    GoogleFonts.spaceGrotesk(),
    GoogleFonts.fraunces(),
  ]);

  runApp(const KoreApp());
}

class KoreApp extends StatelessWidget {
  const KoreApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KORE',
      theme: KoreTheme.darkTheme(),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late BLEService _bleService;
  late SignalProcessor _signalProcessor;

  double _rawValue = 0.0;
  double _filteredValue = 0.0;
  bool _isConnected = false;
  String _connectionStatus = 'Disconnected';
  int _sampleCount = 0;
  String _debugInfo = 'Initializing...';

  @override
  void initState() {
    super.initState();
    _bleService = BLEService();
    _signalProcessor = SignalProcessor();

    // Initialize signal processor with moving average window (50 samples @ 256Hz = ~200ms)
    try {
      _signalProcessor.initialize(50);
      _debugInfo = 'Signal processor ready (window: 50 samples)';
    } catch (e) {
      _debugInfo = 'Error initializing signal processor: $e';
    }

    _setupConnections();
  }

  void _setupConnections() {
    // Listen to connection state changes
    _bleService.connectionStateStream.listen((isConnected) {
      setState(() {
        _isConnected = isConnected;
        _connectionStatus = isConnected ? 'Connected' : 'Disconnected';
        _sampleCount = 0;
        if (!isConnected) {
          _rawValue = 0.0;
          _filteredValue = 0.0;
        }
      });
    });

    // Listen to EEG data
    _bleService.eegDataStream.listen((sample) {
      if (sample.channels.isNotEmpty) {
        final rawValue = sample.channels[0]; // Channel 0

        setState(() {
          _rawValue = rawValue;
          _sampleCount++;

          // Process through signal filter
          try {
            _filteredValue = _signalProcessor.process(rawValue);
            _debugInfo =
                'Sample #$_sampleCount | Raw: ${rawValue.toStringAsFixed(2)} µV | Filtered: ${_filteredValue.toStringAsFixed(2)} µV';
          } catch (e) {
            _debugInfo = 'Processing error: $e';
          }
        });
      }
    });
  }

  Future<void> _scanAndConnect() async {
    setState(() => _debugInfo = 'Scanning for devices...');

    try {
      final devices = await _bleService.scanForDevices();

      if (devices.isEmpty) {
        setState(() => _debugInfo = 'No devices found');
        return;
      }

      setState(() =>
          _debugInfo = 'Found ${devices.length} device(s). Connecting...');

      final success = await _bleService.connect(devices.first.id);

      if (success) {
        setState(() => _debugInfo = 'Connected to ${devices.first.name}');
      } else {
        setState(() => _debugInfo = 'Failed to connect');
      }
    } catch (e) {
      setState(() => _debugInfo = 'Error: $e');
    }
  }

  void _disconnect() async {
    await _bleService.disconnect();
    setState(() {
      _isConnected = false;
      _debugInfo = 'Disconnected';
      _sampleCount = 0;
    });
  }

  @override
  void dispose() {
    _bleService.dispose();
    _signalProcessor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('KORE'),
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Center(
              child: Text(
                _connectionStatus,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: _isConnected
                          ? Theme.of(context).colorScheme.secondary
                          : Colors.grey,
                    ),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Debug Panel (Live Data)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Live Signal Processing',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      SizedBox(height: 16),
                      // Raw vs Filtered comparison
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Raw EEG',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  '${_rawValue.toStringAsFixed(2)} µV',
                                  style: Theme.of(context)
                                      .textTheme
                                      .displaySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .tertiary,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(width: 24),
                          Container(
                            width: 1,
                            height: 80,
                            color: Theme.of(context).dividerColor,
                          ),
                          SizedBox(width: 24),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Filtered (MA-50)',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  '${_filteredValue.toStringAsFixed(2)} µV',
                                  style: Theme.of(context)
                                      .textTheme
                                      .displaySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 24),
                      // Connection & Sample Info
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Samples processed: $_sampleCount @ 256 Hz',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            _bleService.isMockMode ? '(Mock Mode)' : '(BLE)',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      // Debug info
                      Container(
                        padding: EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _debugInfo,
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(height: 16),
                      // Control buttons
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _isConnected ? null : _scanAndConnect,
                              child: Text(
                                _isConnected ? 'Connected' : 'Scan & Connect',
                              ),
                            ),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _isConnected ? _disconnect : null,
                              child: const Text('Disconnect'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Hero Section
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Screenless Focus System',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'The digital dashboard\nfor your mind.',
                    style: Theme.of(context).textTheme.displayMedium,
                  ),
                  SizedBox(height: 16),
                  Text(
                    'KORE helps you reset cognitive strain and sustain focus without relying on nicotine or stimulants.',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  SizedBox(height: 32),
                  Row(
                    children: [
                      ElevatedButton(
                        onPressed: () {},
                        child: const Text('Join the pilot'),
                      ),
                      SizedBox(width: 16),
                      OutlinedButton(
                        onPressed: () {},
                        child: const Text('Request a demo'),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // How It Works Section
            SizedBox(height: 32),
            _buildSectionHeader(context, 'How it works',
                'Closed-loop focus support, not passive content.'),
            SizedBox(height: 16),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: GridView.count(
                crossAxisCount: _getCrossAxisCount(context),
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                shrinkWrap: true,
                physics: NeverScrollableScrollPhysics(),
                children: [
                  _buildFeatureCard(context, 'Detect strain',
                      'KORE learns your baseline and flags focus drift.'),
                  _buildFeatureCard(context, 'Run a reset',
                      'A short protocol helps you return to clarity.'),
                  _buildFeatureCard(context, 'Confirm uplift',
                      'Quick check-ins measure reset effectiveness.'),
                ],
              ),
            ),

            SizedBox(height: 48),
            Center(
              child: Padding(
                padding: EdgeInsets.only(bottom: 32),
                child: Text(
                  'Interested? Email team@kore.health',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String label, String title) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.displaySmall),
        ],
      ),
    );
  }

  Widget _buildFeatureCard(
      BuildContext context, String title, String description) {
    return Card(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            SizedBox(height: 12),
            Text(description, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  int _getCrossAxisCount(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width > 1200) return 3;
    if (width > 600) return 2;
    return 1;
  }
}
