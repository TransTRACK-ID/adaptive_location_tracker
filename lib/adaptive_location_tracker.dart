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
  ///
  /// Safe to call again at any time, including while a session is already
  /// active -- if the current instance is tracking, it's stopped first
  /// (native service disarmed, iOS stream cancelled) before being replaced,
  /// so callers no longer need to remember to call [stop] themselves
  /// before reconfiguring. Previously this was a documented caller
  /// obligation; callers that skipped it (calling [configure]/[start]
  /// again while already tracking) would leave the native side running
  /// and then re-arm on top of it via a second `start` invocation.
  static Future<void> configure(AdaptiveLocationTrackerConfig config) async {
    if (_instance?.isTracking ?? false) {
      await _instance!.stop();
    }
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

  /// Whether a tracking session is currently active. Calling [start]
  /// again while this is `true` is safe (no-op success); calling
  /// [configure] again while this is `true` safely stops the current
  /// session first.
  static bool get isTracking => _instance?.isTracking ?? false;

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
