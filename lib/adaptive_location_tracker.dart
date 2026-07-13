library adaptive_location_tracker;

export 'src/adaptive_filter.dart'
    show
        MovementMode,
        AdaptiveLocationFilter,
        LocationFilterConfig,
        ActivityBridge,
        BatteryHelper;
export 'src/location_cache.dart' show LocationCache;
export 'src/adaptive_location_tracker_controller.dart'
    show AdaptiveLocationTrackerController, StartResult;
export 'src/models.dart'
    show
        LocationFix,
        SendResult,
        TrackingSyncEvent,
        TrackingSyncEventType,
        NativeFieldKeys,
        NativeEndpointConfig,
        DegradedModeConfig,
        AdaptiveFilterConfig,
        AdaptiveLocationTrackerConfig;
export 'src/native_bridge.dart' show NativeBridge;

import 'src/adaptive_location_tracker_controller.dart';
import 'src/models.dart';
import 'src/native_bridge.dart';

/// Static facade over [AdaptiveLocationTrackerController] for apps that only need a
/// single tracking session (the common case). Multi-session or testable
/// usage should construct [AdaptiveLocationTrackerController] directly instead.
class AdaptiveLocationTracker {
  AdaptiveLocationTracker._();

  static AdaptiveLocationTrackerController? _instance;

  /// Configures the tracking flow. Must be called once before [start].
  /// Safe to call again to update config between sessions (call [stop]
  /// first if a session is active).
  static Future<void> configure(AdaptiveLocationTrackerConfig config) async {
    _instance?.dispose();
    _instance = AdaptiveLocationTrackerController(config);
    await _instance!.configure();
  }

  static AdaptiveLocationTrackerController get _requireInstance {
    final instance = _instance;
    if (instance == null) {
      throw StateError(
        'AdaptiveLocationTracker.configure(...) must be called before using AdaptiveLocationTracker.',
      );
    }
    return instance;
  }

  static Future<StartResult> start() => _requireInstance.start();

  static Future<void> stop() => _requireInstance.stop();

  /// Fire-and-forget: ask the native layer to drain its offline queue.
  static void tryFlush() => _requireInstance.tryFlush();

  /// Broadcast stream of native background-flush events.
  static Stream<TrackingSyncEvent> get syncEvents =>
      NativeBridge.syncEventStream;

  static void dispose() {
    _instance?.dispose();
    _instance = null;
  }
}
