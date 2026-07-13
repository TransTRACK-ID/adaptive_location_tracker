import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the last successfully *sent* location fix across app restarts
/// and background-isolate boundaries.
///
/// The persisted copy is used by [AdaptiveLocationFilter] to compute
/// distance/time/angle deltas for every new fix so we never send redundant
/// data to the server.
class LocationCache {
  LocationCache._();

  static const _kLat = 'adaptive_location_tracker_loc_cache_lat';
  static const _kLon = 'adaptive_location_tracker_loc_cache_lon';
  static const _kHeading = 'adaptive_location_tracker_loc_cache_heading';
  static const _kSpeed = 'adaptive_location_tracker_loc_cache_speed';
  static const _kTimestamp = 'adaptive_location_tracker_loc_cache_timestamp';

  /// In-memory fast-path. Populated on first [load] or after [save].
  static Position? _cached;

  static Position? get last => _cached;

  /// Loads the last persisted position from [SharedPreferences].
  /// Returns null on first-ever run (no previous fix stored).
  static Future<Position?> load() async {
    if (_cached != null) return _cached;

    final prefs = await SharedPreferences.getInstance();
    final lat = prefs.getDouble(_kLat);
    final lon = prefs.getDouble(_kLon);
    final ts = prefs.getString(_kTimestamp);

    if (lat == null || lon == null || ts == null) return null;

    _cached = Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime.tryParse(ts) ?? DateTime.now(),
      accuracy: 0,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: prefs.getDouble(_kHeading) ?? -1,
      headingAccuracy: 0,
      speed: prefs.getDouble(_kSpeed) ?? 0,
      speedAccuracy: 0,
      isMocked: false,
    );

    return _cached;
  }

  /// Persists [position] as the last successfully sent fix.
  /// Call this only AFTER a successful send.
  static Future<void> save(Position position) async {
    _cached = position;
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setDouble(_kLat, position.latitude),
      prefs.setDouble(_kLon, position.longitude),
      prefs.setDouble(_kHeading, position.heading),
      prefs.setDouble(_kSpeed, position.speed),
      prefs.setString(_kTimestamp, position.timestamp.toIso8601String()),
    ]);
  }

  /// Wipes the in-memory cache only (e.g. on check-out / stop).
  /// Persisted data remains so the next start still has a starting point.
  static void clearMemory() => _cached = null;

  /// Clears the in-memory cache AND forces SharedPreferences to re-read from
  /// NSUserDefaults (iOS) / the platform store (Android).
  ///
  /// Call this at the foreground-resume boundary so the Dart filter sees the
  /// fixes that the native layer sent during the background session, not the
  /// stale in-memory value from before the app was backgrounded.
  static Future<Position?> forceReload() async {
    _cached = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // pick up native NSUserDefaults writes
    return load();
  }
}
