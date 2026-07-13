import 'package:geolocator/geolocator.dart';

/// A single location fix, in a transport-agnostic shape.
///
/// This wraps [Position] from `geolocator` today (Dart-side foreground /
/// legacy-queue paths use it directly), but keeping it as our own type means
/// the native queue formats (Android SQLite, iOS SQLite) can also be decoded
/// into it without depending on geolocator internals.
class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    required this.accuracy,
    required this.speed,
    required this.heading,
    required this.altitude,
    this.isMocked = false,
    this.batteryLevel,
  });

  factory LocationFix.fromPosition(Position position, {int? batteryLevel}) {
    return LocationFix(
      latitude: position.latitude,
      longitude: position.longitude,
      timestamp: position.timestamp,
      accuracy: position.accuracy,
      speed: position.speed,
      heading: position.heading,
      altitude: position.altitude,
      isMocked: position.isMocked,
      batteryLevel: batteryLevel,
    );
  }

  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final double accuracy;
  final double speed; // m/s
  final double heading; // degrees
  final double altitude;
  final bool isMocked;
  final int? batteryLevel;

  double get speedKmh => speed * 3.6;

  Position toPosition() => Position(
        latitude: latitude,
        longitude: longitude,
        timestamp: timestamp,
        accuracy: accuracy,
        altitude: altitude,
        altitudeAccuracy: 0,
        heading: heading,
        headingAccuracy: 0,
        speed: speed,
        speedAccuracy: 0,
        isMocked: isMocked,
      );
}

/// Result of a host-app send attempt, returned from [AdaptiveLocationTrackerConfig.onSend].
///
/// The distinction between [isClientError] and a generic failure matters:
/// a 4xx (malformed payload) should be discarded from the offline queue since
/// it will never succeed, whereas a 5xx/network failure should be retried.
class SendResult {
  const SendResult.success() : isSuccess = true, isClientError = false;

  const SendResult.retryableFailure()
      : isSuccess = false,
        isClientError = false;

  const SendResult.discard() : isSuccess = false, isClientError = true;

  final bool isSuccess;
  final bool isClientError;
}

/// Type of background-sync event surfaced from the native layer.
enum TrackingSyncEventType { begin, end }

/// A background offline-queue flush event, posted by the native layer
/// (Android's foreground service, iOS's kill-survival service) whenever it
/// drains its own SQLite queue independently of Dart.
class TrackingSyncEvent {
  const TrackingSyncEvent.begin(this.count)
      : type = TrackingSyncEventType.begin,
        sent = 0,
        kept = 0,
        discarded = 0;

  const TrackingSyncEvent.end({
    required this.sent,
    required this.kept,
    required this.discarded,
  })  : type = TrackingSyncEventType.end,
        count = 0;

  final TrackingSyncEventType type;

  /// Rows about to be flushed. Only valid when [type] is `begin`.
  final int count;

  /// Rows successfully sent. Only valid when [type] is `end`.
  final int sent;

  /// Rows kept in the queue for retry. Only valid when [type] is `end`.
  final int kept;

  /// Rows discarded as malformed (e.g. 4xx). Only valid when [type] is `end`.
  final int discarded;
}

/// Query-parameter key names used by the *native* HTTP sender (Android's
/// foreground service, iOS's kill-survival service) when it posts a location
/// fix directly — i.e. while the Flutter engine isn't running and
/// [AdaptiveLocationTrackerConfig.onSend] can't be invoked.
///
/// Defaults match a Traccar-style OsmAnd protocol. Override per-field to
/// match your own backend's query-string contract without needing to fork
/// the native code.
class NativeFieldKeys {
  const NativeFieldKeys({
    this.subjectId = 'id',
    this.timestamp = 'timestamp',
    this.latitude = 'lat',
    this.longitude = 'lon',
    this.speed = 'speed',
    this.bearing = 'bearing',
    this.altitude = 'altitude',
    this.accuracy = 'accuracy',
    this.battery = 'batt',
  });

  final String subjectId;
  final String timestamp;
  final String latitude;
  final String longitude;
  final String speed;
  final String bearing;
  final String altitude;
  final String accuracy;
  final String battery;

  Map<String, String> toMap() => {
        'subjectId': subjectId,
        'timestamp': timestamp,
        'latitude': latitude,
        'longitude': longitude,
        'speed': speed,
        'bearing': bearing,
        'altitude': altitude,
        'accuracy': accuracy,
        'battery': battery,
      };
}

/// Configuration for the native (Flutter-engine-independent) sender.
///
/// [trackingUrl] and [subjectId] are persisted natively (SharedPreferences on
/// Android, NSUserDefaults on iOS) so they survive process death — the whole
/// point of this layer is that it must keep working when Dart isn't running.
class NativeEndpointConfig {
  const NativeEndpointConfig({
    required this.trackingUrl,
    required this.subjectId,
    this.fieldKeys = const NativeFieldKeys(),
  });

  final String trackingUrl;
  final String subjectId;
  final NativeFieldKeys fieldKeys;

  Map<String, dynamic> toChannelArgs() => {
        'url': trackingUrl,
        'subjectId': subjectId,
        'fieldKeys': fieldKeys.toMap(),
      };
}

/// Degraded-mode backoff configuration — used when consecutive sends fail,
/// to fall back to a longer interval instead of hammering a possibly-down
/// backend.
class DegradedModeConfig {
  const DegradedModeConfig({
    this.consecutiveFailureThreshold = 2,
    this.degradedIntervalSeconds = 900,
  });

  final int consecutiveFailureThreshold;
  final int degradedIntervalSeconds;
}

/// Per-movement-mode tuning knobs for the adaptive filter. Defaults mirror
/// the values proven out in production; override only if your use case
/// (e.g. delivery bikes only, no driving) calls for it.
class AdaptiveFilterConfig {
  const AdaptiveFilterConfig({
    this.movingIntervalSeconds = 15,
    this.stationaryHeartbeatSeconds = 60,
    this.walkingFastestSeconds = 15,
    this.cyclingFastestSeconds = 8,
    this.drivingFastestSeconds = 5,
    this.baseDistanceMetres = 20,
    this.angleThresholdDeg = 25,
    this.walkToCyclingSpeedKmh = 5.0,
    this.cyclingToDrivingSpeedKmh = 15.0,
    this.drivingSpeedFloorKmh = 40.0,
    this.drivingAccuracyMetres = 50.0,
    this.walkingAccuracyMetres = 20.0,
    this.cyclingAccuracyMetres = 30.0,
  });

  final int movingIntervalSeconds;
  final int stationaryHeartbeatSeconds;
  final int walkingFastestSeconds;
  final int cyclingFastestSeconds;
  final int drivingFastestSeconds;
  final int baseDistanceMetres;
  final int angleThresholdDeg;
  final double walkToCyclingSpeedKmh;
  final double cyclingToDrivingSpeedKmh;
  final double drivingSpeedFloorKmh;
  final double drivingAccuracyMetres;
  final double walkingAccuracyMetres;
  final double cyclingAccuracyMetres;
}

/// Top-level configuration for [AdaptiveLocationTracker.configure].
class AdaptiveLocationTrackerConfig {
  const AdaptiveLocationTrackerConfig({
    required this.onSend,
    required this.native,
    this.filter = const AdaptiveFilterConfig(),
    this.degradedMode = const DegradedModeConfig(),
    this.onLog,
    this.onSyncEvent,
    this.ensureAndroidBatteryExemption,
  });

  /// Dart-side send callback. Invoked whenever the Flutter engine is alive
  /// and a fix passes the adaptive filter:
  ///   - iOS foreground position stream
  ///   - Android/iOS legacy-queue flush path
  ///
  /// Not invoked for native-layer sends (Android foreground service, iOS
  /// backgrounded kill-survival service) — those use [native] directly since
  /// Dart may not be running.
  final Future<SendResult> Function(LocationFix fix) onSend;

  /// Endpoint contract used by the native senders. Required even if your
  /// backend is only ever hit from Dart today — the native layer is what
  /// keeps tracking alive when the app is backgrounded/killed.
  final NativeEndpointConfig native;

  final AdaptiveFilterConfig filter;
  final DegradedModeConfig degradedMode;

  /// Optional log sink. Defaults to no-op; wire to your app's logger.
  final void Function(String message)? onLog;

  /// Optional sink for native background-flush events (e.g. to show a
  /// "syncing N offline points" toast).
  final void Function(TrackingSyncEvent event)? onSyncEvent;

  /// Android only. Called before starting the service; return `true` once
  /// the user is exempted from battery optimization (or exemption isn't
  /// required for your use case). Return `false` to abort starting.
  /// If omitted, the exemption check is skipped entirely.
  final Future<bool> Function()? ensureAndroidBatteryExemption;
}
