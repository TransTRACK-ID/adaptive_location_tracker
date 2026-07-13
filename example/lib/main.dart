import 'package:flutter/material.dart';
import 'package:adaptive_location_tracker/adaptive_location_tracker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AdaptiveLocationTracker.configure(
    AdaptiveLocationTrackerConfig(
      onSend: (fix) async {
        // Replace with your real backend call.
        debugPrint('Would send: ${fix.latitude}, ${fix.longitude}');
        return const SendResult.success();
      },
      native: const NativeEndpointConfig(
        trackingUrl: 'https://example.com/api/location',
        subjectId: 'demo-user',
      ),
      onLog: debugPrint,
      onSyncEvent: (event) => debugPrint('Sync event: ${event.type}'),
    ),
  );

  runApp(const ExampleApp());
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  bool _tracking = false;

  Future<void> _toggle() async {
    if (_tracking) {
      await AdaptiveLocationTracker.stop();
    } else {
      final result = await AdaptiveLocationTracker.start();
      if (result != StartResult.started) {
        debugPrint('Start failed: $result');
        return;
      }
    }
    setState(() => _tracking = !_tracking);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('adaptive_location_tracker example')),
        body: Center(
          child: ElevatedButton(
            onPressed: _toggle,
            child: Text(_tracking ? 'Stop tracking' : 'Start tracking'),
          ),
        ),
      ),
    );
  }
}
