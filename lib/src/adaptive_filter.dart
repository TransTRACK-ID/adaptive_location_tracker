import 'package:battery_plus/battery_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'location_cache.dart';
import 'models.dart';

/// Movement mode — driven by Activity Recognition (Android) / Core Motion
/// (iOS) when available, with GPS-speed fallback.
enum MovementMode { stationary, walking, cycling, driving }

/// Hysteresis state (in-memory only). Prevents rapid mode flapping (e.g.
/// walking -> GPS hiccup -> stationary -> walking) by requiring a mode to be
/// stable for a minimum time before committing.
class _HysteresisState {
  _HysteresisState._();

  static MovementMode _committed = MovementMode.stationary;
  static MovementMode _candidate = MovementMode.stationary;
  static DateTime _candidateSince = DateTime.now();

  static const _thresholds = {
    MovementMode.stationary: 60,
    MovementMode.walking: 30,
    MovementMode.cycling: 15,
    MovementMode.driving: 0,
  };

  static MovementMode commit(MovementMode raw) {
    final now = DateTime.now();

    if (raw == _candidate) {
      final stableSec = now.difference(_candidateSince).inSeconds;
      final required = _thresholds[raw] ?? 0;
      final isUpgrade = raw.index > _committed.index;
      if (isUpgrade || stableSec >= required) {
        _committed = raw;
      }
    } else {
      _candidate = raw;
      _candidateSince = now;
      if (raw.index > _committed.index) {
        _committed = raw;
      }
    }

    return _committed;
  }

  static void reset() {
    _committed = MovementMode.stationary;
    _candidate = MovementMode.stationary;
    _candidateSince = DateTime.now();
  }
}

/// Activity-recognition bridge (written by an activity-recognition plugin,
/// or by the native layer from CMMotionActivityManager on iOS).
///
/// If you don't wire an activity-recognition source, this simply stays
/// absent and the filter falls back to GPS speed — fully optional.
///
/// Key:  'adaptive_location_tracker_activity_type'
/// Values: 'stationary' | 'walking' | 'cycling' | 'automotive' | 'unknown'
class ActivityBridge {
  ActivityBridge._();

  static const kKey = 'adaptive_location_tracker_activity_type';
  static const kTimestampKey = 'adaptive_location_tracker_activity_type_ts';
  static const _kStaleMs = 30000;

  static Future<MovementMode?> read() async {
    final p = await SharedPreferences.getInstance();
    await p.reload();

    final type = p.getString(kKey);
    final ts = p.getInt(kTimestampKey) ?? 0;

    if (type == null) return null;

    final ageMs = DateTime.now().millisecondsSinceEpoch - ts;
    if (ageMs > _kStaleMs) return null;

    switch (type) {
      case 'stationary':
        return MovementMode.stationary;
      case 'walking':
        return MovementMode.walking;
      case 'cycling':
        return MovementMode.cycling;
      case 'automotive':
        return MovementMode.driving;
      default:
        return null;
    }
  }
}

class BatteryHelper {
  BatteryHelper._();

  static int _cachedLevel = 100;
  static DateTime _lastRead = DateTime.fromMillisecondsSinceEpoch(0);
  static const _kCacheDuration = Duration(minutes: 2);

  static Future<int> get level async {
    final now = DateTime.now();
    if (now.difference(_lastRead) > _kCacheDuration) {
      try {
        _cachedLevel = await Battery().batteryLevel;
        _lastRead = now;
      } catch (_) {}
    }
    return _cachedLevel;
  }

  /// Interval multiplier based on battery level:
  ///   > 50%  -> 1.0x (normal)
  ///   20-50% -> 1.5x
  ///   < 20%  -> 2.5x
  static Future<double> get intervalMultiplier async {
    final lvl = await level;
    if (lvl > 50) return 1.0;
    if (lvl > 20) return 1.5;
    return 2.5;
  }
}

class _ModeConfig {
  final int fastestSec;
  final double minAccuracyM;
  final int angleThresholdDeg;
  final double headingMinSpeedKmh;
  final double targetTimeWindowSec;
  final double minDistanceM;

  const _ModeConfig({
    required this.fastestSec,
    required this.minAccuracyM,
    required this.angleThresholdDeg,
    required this.headingMinSpeedKmh,
    required this.targetTimeWindowSec,
    required this.minDistanceM,
  });
}

/// Runtime-tunable, persisted configuration for the adaptive filter.
///
/// Seeded from [AdaptiveFilterConfig]/[DegradedModeConfig] on first
/// [ensureWritten], then stored in SharedPreferences so both Dart and any
/// native code you wire up read the same live values (and so they can be
/// tuned remotely, e.g. via a remote-config fetch, without an app update).
///
/// If you have a native (Android/iOS) implementation reading these same
/// keys, keep the key names in sync — see the `adaptive_location_tracker_` package's
/// native source for the matching constants.
class LocationFilterConfig {
  LocationFilterConfig._();

  static const kInterval = 'adaptive_location_tracker_filter_interval_sec';
  static const kHeartbeat = 'adaptive_location_tracker_filter_heartbeat_sec';
  static const kFastestInterval = 'adaptive_location_tracker_filter_fastest_sec';
  static const kFastestCyclingInterval =
      'adaptive_location_tracker_filter_fastest_cycling_sec';
  static const kFastestDrivingInterval =
      'adaptive_location_tracker_filter_fastest_driving_sec';
  static const kDistance = 'adaptive_location_tracker_filter_distance_m';
  static const kAngle = 'adaptive_location_tracker_filter_angle_deg';
  static const kSpeedThreshold = 'adaptive_location_tracker_filter_speed_kmh';
  static const kSpeedCycling = 'adaptive_location_tracker_filter_speed_cycling_kmh';
  static const kSpeedDriving = 'adaptive_location_tracker_filter_speed_driving_kmh';
  static const kDegradedMode = 'adaptive_location_tracker_filter_degraded_mode';
  static const kAccuracy = 'adaptive_location_tracker_filter_accuracy_m';
  static const kAccuracyWalking = 'adaptive_location_tracker_filter_accuracy_walking_m';
  static const kAccuracyCycling = 'adaptive_location_tracker_filter_accuracy_cycling_m';

  /// Ownership flag (iOS only) — 'flutter' while the Dart position stream
  /// owns capture, 'native' once the native background service takes over.
  static const kOwner = 'adaptive_location_tracker_ks_owner';
  static const kOwnerFlutter = 'flutter';
  static const kOwnerNative = 'native';

  /// Cross-layer flush mutex (iOS only).
  static const kFlushing = 'adaptive_location_tracker_ks_flushing';

  static int _degradedFailureThreshold = 2;
  static int _degradedIntervalSec = 900;

  static int get degradedFailureThreshold => _degradedFailureThreshold;
  static int get degradedIntervalSec => _degradedIntervalSec;

  static Future<int> get interval async =>
      (await SharedPreferences.getInstance()).getInt(kInterval) ?? 15;

  static Future<int> get heartbeatInterval async =>
      (await SharedPreferences.getInstance()).getInt(kHeartbeat) ?? 60;

  static Future<int> get fastestInterval async =>
      (await SharedPreferences.getInstance()).getInt(kFastestInterval) ?? 15;

  static Future<int> get fastestCyclingInterval async =>
      (await SharedPreferences.getInstance())
          .getInt(kFastestCyclingInterval) ??
      8;

  static Future<int> get fastestDrivingInterval async =>
      (await SharedPreferences.getInstance())
          .getInt(kFastestDrivingInterval) ??
      5;

  static Future<int> get distanceFilter async =>
      (await SharedPreferences.getInstance()).getInt(kDistance) ?? 20;

  static Future<double> get speedThresholdKmh async =>
      (await SharedPreferences.getInstance()).getDouble(kSpeedThreshold) ??
      5.0;

  static Future<double> get speedCyclingKmh async =>
      (await SharedPreferences.getInstance()).getDouble(kSpeedCycling) ?? 15.0;

  static Future<double> get speedDrivingKmh async =>
      (await SharedPreferences.getInstance()).getDouble(kSpeedDriving) ?? 40.0;

  static Future<double> get minAccuracyMetres async =>
      (await SharedPreferences.getInstance()).getDouble(kAccuracy) ?? 50.0;

  static Future<double> get minAccuracyWalkingMetres async =>
      (await SharedPreferences.getInstance()).getDouble(kAccuracyWalking) ??
      20.0;

  static Future<double> get minAccuracyCyclingMetres async =>
      (await SharedPreferences.getInstance()).getDouble(kAccuracyCycling) ??
      30.0;

  static Future<bool> get isDegradedMode async =>
      (await SharedPreferences.getInstance()).getBool(kDegradedMode) ?? false;

  static Future<void> setDegradedMode(bool active) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kDegradedMode, active);
  }

  static Future<String> get owner async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    return p.getString(kOwner) ?? kOwnerFlutter;
  }

  static Future<void> setOwner(String value) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(kOwner, value);
  }

  static Future<bool> get isFlushing async {
    final p = await SharedPreferences.getInstance();
    await p.reload();
    return p.getBool(kFlushing) ?? false;
  }

  static Future<double> accuracyForMode(MovementMode mode) async {
    switch (mode) {
      case MovementMode.walking:
        return minAccuracyWalkingMetres;
      case MovementMode.cycling:
        return minAccuracyCyclingMetres;
      case MovementMode.stationary:
      case MovementMode.driving:
        return minAccuracyMetres;
    }
  }

  static Future<int> fastestIntervalForMode(MovementMode mode) async {
    switch (mode) {
      case MovementMode.driving:
        return fastestDrivingInterval;
      case MovementMode.cycling:
        return fastestCyclingInterval;
      case MovementMode.walking:
        return fastestInterval;
      case MovementMode.stationary:
        return 0;
    }
  }

  /// Detects the raw movement mode from speed (with GPS-speed fallback).
  /// Passes through [_HysteresisState.commit] to prevent flapping.
  ///
  /// Priority:
  ///   1. Activity Recognition / Core Motion (via [ActivityBridge])
  ///   2. GPS speed (current.speed)
  ///   3. Distance-over-time inference (when speed < 0)
  static Future<MovementMode> detectMode(
    double speedKmh, {
    Position? current,
  }) async {
    final activityMode = await ActivityBridge.read();
    if (activityMode != null) {
      return _HysteresisState.commit(activityMode);
    }

    if (speedKmh < 0) {
      if (current != null) {
        final last = await LocationCache.load();
        if (last != null) {
          final elapsedSec =
              current.timestamp.difference(last.timestamp).inSeconds;
          if (elapsedSec > 0) {
            final distM = Geolocator.distanceBetween(
              last.latitude,
              last.longitude,
              current.latitude,
              current.longitude,
            );
            speedKmh = (distM / elapsedSec) * 3.6;
          } else {
            speedKmh = double.infinity;
          }
        } else {
          speedKmh = double.infinity;
        }
      } else {
        speedKmh = double.infinity;
      }
    }

    final walkBoundary = await speedThresholdKmh;
    final cyclingBoundary = await speedCyclingKmh;
    final drivingBoundary = await speedDrivingKmh;

    MovementMode raw;
    if (speedKmh < walkBoundary) {
      raw = MovementMode.stationary;
    } else if (speedKmh < cyclingBoundary) {
      raw = MovementMode.walking;
    } else if (speedKmh < drivingBoundary) {
      raw = MovementMode.cycling;
    } else {
      raw = MovementMode.driving;
    }

    return _HysteresisState.commit(raw);
  }

  /// Seeds every threshold key from [filterConfig]/[degradedConfig] if not
  /// already present. Safe to call repeatedly (idempotent) — call this once
  /// from [AdaptiveLocationTracker.configure].
  static Future<void> ensureWritten(
    AdaptiveFilterConfig filterConfig,
    DegradedModeConfig degradedConfig,
  ) async {
    _degradedFailureThreshold = degradedConfig.consecutiveFailureThreshold;
    _degradedIntervalSec = degradedConfig.degradedIntervalSeconds;

    final p = await SharedPreferences.getInstance();
    await Future.wait([
      if (!p.containsKey(kInterval))
        p.setInt(kInterval, filterConfig.movingIntervalSeconds),
      if (!p.containsKey(kHeartbeat))
        p.setInt(kHeartbeat, filterConfig.stationaryHeartbeatSeconds),
      if (!p.containsKey(kFastestInterval))
        p.setInt(kFastestInterval, filterConfig.walkingFastestSeconds),
      if (!p.containsKey(kFastestCyclingInterval))
        p.setInt(kFastestCyclingInterval, filterConfig.cyclingFastestSeconds),
      if (!p.containsKey(kFastestDrivingInterval))
        p.setInt(kFastestDrivingInterval, filterConfig.drivingFastestSeconds),
      if (!p.containsKey(kDistance))
        p.setInt(kDistance, filterConfig.baseDistanceMetres),
      if (!p.containsKey(kAngle))
        p.setInt(kAngle, filterConfig.angleThresholdDeg),
      if (!p.containsKey(kSpeedThreshold))
        p.setDouble(kSpeedThreshold, filterConfig.walkToCyclingSpeedKmh),
      if (!p.containsKey(kSpeedCycling))
        p.setDouble(kSpeedCycling, filterConfig.cyclingToDrivingSpeedKmh),
      if (!p.containsKey(kSpeedDriving))
        p.setDouble(kSpeedDriving, filterConfig.drivingSpeedFloorKmh),
      if (!p.containsKey(kAccuracy))
        p.setDouble(kAccuracy, filterConfig.drivingAccuracyMetres),
      if (!p.containsKey(kAccuracyWalking))
        p.setDouble(kAccuracyWalking, filterConfig.walkingAccuracyMetres),
      if (!p.containsKey(kAccuracyCycling))
        p.setDouble(kAccuracyCycling, filterConfig.cyclingAccuracyMetres),
    ]);
  }

  static void resetHysteresis() => _HysteresisState.reset();
}

Map<MovementMode, _ModeConfig> _buildModeConfigs(AdaptiveFilterConfig cfg) => {
      MovementMode.stationary: _ModeConfig(
        fastestSec: 60,
        minAccuracyM: 50,
        angleThresholdDeg: 0,
        headingMinSpeedKmh: double.infinity,
        targetTimeWindowSec: 0,
        minDistanceM: 0,
      ),
      MovementMode.walking: const _ModeConfig(
        fastestSec: 15,
        minAccuracyM: 20,
        angleThresholdDeg: 0,
        headingMinSpeedKmh: double.infinity,
        targetTimeWindowSec: 15,
        minDistanceM: 15,
      ),
      MovementMode.cycling: _ModeConfig(
        fastestSec: cfg.cyclingFastestSeconds,
        minAccuracyM: cfg.cyclingAccuracyMetres,
        angleThresholdDeg: cfg.angleThresholdDeg,
        headingMinSpeedKmh: cfg.walkToCyclingSpeedKmh + 3,
        targetTimeWindowSec: 10,
        minDistanceM: 40,
      ),
      MovementMode.driving: _ModeConfig(
        fastestSec: cfg.drivingFastestSeconds,
        minAccuracyM: cfg.drivingAccuracyMetres,
        angleThresholdDeg: cfg.angleThresholdDeg,
        headingMinSpeedKmh: cfg.walkToCyclingSpeedKmh + 3,
        targetTimeWindowSec: 7,
        minDistanceM: 75,
      ),
    };

/// Computes the adaptive distance filter for a given mode and speed (m/s).
///   distFilter = max(minDistance, speedMps x targetTimeWindow)
double _adaptiveDistanceFilter(_ModeConfig cfg, double speedMps) {
  if (speedMps <= 0 || cfg.targetTimeWindowSec <= 0) return cfg.minDistanceM;
  final computed = speedMps * cfg.targetTimeWindowSec;
  return computed < cfg.minDistanceM ? cfg.minDistanceM : computed;
}

/// Decides whether a given [Position] fix is worth sending, based on
/// movement mode, adaptive distance/time thresholds, accuracy gates, and
/// heading-change detection.
class AdaptiveLocationFilter {
  AdaptiveLocationFilter(this._config);

  final AdaptiveFilterConfig _config;

  Future<bool> shouldSend(Position current, {bool isForced = false}) async {
    if (isForced) return true;

    final last = await LocationCache.load();
    if (last == null) return true;

    final durationSec = current.timestamp.difference(last.timestamp).inSeconds;
    final speedKmh = current.speed * 3.6;
    final speedMps = current.speed.clamp(0, double.infinity).toDouble();
    final mode =
        await LocationFilterConfig.detectMode(speedKmh, current: current);

    final maxAccuracy = await LocationFilterConfig.accuracyForMode(mode);
    if (current.accuracy > maxAccuracy) return false;

    final fastestSec = await LocationFilterConfig.fastestIntervalForMode(mode);
    final batteryMult = await BatteryHelper.intervalMultiplier;
    final effectiveFastest = (fastestSec * batteryMult).round();

    if (durationSec < effectiveFastest) return false;

    if (mode == MovementMode.stationary) {
      final heartbeatSec = await LocationFilterConfig.heartbeatInterval;
      return durationSec >= heartbeatSec;
    }

    final distanceM = Geolocator.distanceBetween(
      last.latitude,
      last.longitude,
      current.latitude,
      current.longitude,
    );

    final modeConfigs = _buildModeConfigs(_config);
    final modeCfg = modeConfigs[mode]!;
    final adaptiveDist = _adaptiveDistanceFilter(modeCfg, speedMps);

    final baseInterval = await LocationFilterConfig.isDegradedMode
        ? LocationFilterConfig.degradedIntervalSec
        : await LocationFilterConfig.interval;
    final effectiveInterval = (baseInterval * batteryMult).round();

    // Time OR distance — either threshold alone is sufficient. A brief stop
    // (red light, junction) shouldn't delay the next send by a full extra
    // interval just because distanceM reset to zero.
    if (durationSec >= effectiveInterval) return true;
    if (distanceM >= adaptiveDist) return true;

    // Heading-change threshold — mode-specific, speed-gated.
    if (modeCfg.angleThresholdDeg > 0 &&
        last.heading >= 0 &&
        current.heading >= 0 &&
        speedKmh > modeCfg.headingMinSpeedKmh) {
      var headingDiff = (current.heading - last.heading).abs();
      if (headingDiff > 180) headingDiff = 360 - headingDiff;
      if (headingDiff >= modeCfg.angleThresholdDeg) return true;
    }

    return false;
  }
}
