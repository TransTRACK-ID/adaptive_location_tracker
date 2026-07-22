import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:geolocator/geolocator.dart' hide ActivityType;
import 'package:geolocator/geolocator.dart' as geo;

import 'adaptive_filter.dart';
import 'location_cache.dart';
import 'models.dart';
import 'native_bridge.dart';

/// Result of an [AdaptiveLocationTrackerController.start] attempt.
enum StartResult {
  started,
  permissionDenied,
  androidBatteryExemptionDenied,
}

/// Orchestrates the full live-tracking flow across both platforms:
///
///   - Android: the native foreground service does everything (capture,
///     filter mirror, offline queue, HTTP send) once armed via
///     [NativeBridge.start]. This controller's job on Android is just
///     permission/battery-exemption gating plus relaying config.
///
///   - iOS: this controller owns a Dart-side foreground position stream
///     (active only while the app is foregrounded and "owns" capture --
///     see [LocationFilterConfig.owner]). When the app backgrounds, the
///     host app's AppDelegate hands ownership to the native kill-survival
///     service, which captures/queues/sends independently of Dart.
///
/// One instance is enough per app; [AdaptiveLocationTracker] (the public entrypoint)
/// keeps a single static instance for you.
class AdaptiveLocationTrackerController {
  AdaptiveLocationTrackerController(this._config)
      : _filter = AdaptiveLocationFilter(_config.filter);

  final AdaptiveLocationTrackerConfig _config;
  final AdaptiveLocationFilter _filter;

  StreamSubscription<Position>? _iosPositionStream;
  bool _isStarting = false;
  bool _isFlushing = false;
  int _consecutiveFailures = 0;
  bool _configured = false;
  bool _isTracking = false;

  /// Whether a tracking session is currently active on this controller
  /// (i.e. [start] has completed successfully and [stop] hasn't been
  /// called since). Callers can use this to avoid calling [start] again
  /// while a session is already running.
  bool get isTracking => _isTracking;

  /// Broadcast stream of native background-flush events (e.g. to show a
  /// "syncing N offline points" indicator). Equivalent to subscribing to
  /// [NativeBridge.syncEventStream] directly, but only emits if you set
  /// [AdaptiveLocationTrackerConfig.onSyncEvent] — most apps should just use that
  /// callback instead of this stream.
  Stream<TrackingSyncEvent> get syncEvents => NativeBridge.syncEventStream;
  StreamSubscription<TrackingSyncEvent>? _syncEventSub;

  /// Seeds persisted filter thresholds and starts forwarding native sync
  /// events to [AdaptiveLocationTrackerConfig.onSyncEvent]. Call once, before [start].
  Future<void> configure() async {
    if (_configured) return;
    _configured = true;

    await LocationFilterConfig.ensureWritten(
      _config.filter,
      _config.degradedMode,
    );

    if (_config.onSyncEvent != null) {
      _syncEventSub = NativeBridge.syncEventStream.listen(
        _config.onSyncEvent,
        onError: (Object e) => _log('syncEventStream error: $e'),
      );
    }
  }

  /// Starts tracking. On Android this arms the native foreground service
  /// (after confirming battery-optimization exemption, if configured); on
  /// iOS this also starts the Dart-side foreground position stream.
  Future<StartResult> start() async {
    // Idempotency guard: a repeat `start()` call while a session is
    // already active must not re-arm the native service or spin up a
    // second iOS position stream on top of a running one -- both would
    // leave the native side with duplicate listeners/callbacks. Since the
    // session is already up, this is just a no-op success.
    if (_isTracking) return StartResult.started;

    if (Platform.isAndroid && _config.ensureAndroidBatteryExemption != null) {
      final exempted = await _config.ensureAndroidBatteryExemption!();
      if (!exempted) return StartResult.androidBatteryExemptionDenied;
    }

    final hasPermission = await _ensurePermission();
    if (!hasPermission) return StartResult.permissionDenied;

    await NativeBridge.setTrackingConfig(_config.native);
    await NativeBridge.start();

    if (Platform.isIOS) {
      await LocationFilterConfig.setOwner(LocationFilterConfig.kOwnerFlutter);
      unawaited(_startIosStream());
    }

    _isTracking = true;
    return StartResult.started;
  }

  /// Stops tracking on both the native side and (on iOS) the Dart stream.
  Future<void> stop() async {
    await NativeBridge.stop();
    if (Platform.isIOS) {
      await _stopIosStream();
    }
    _isStarting = false;
    _isTracking = false;
    LocationCache.clearMemory();
  }

  /// Fire-and-forget flush of the native offline queue. Safe to call
  /// repeatedly; no-ops while a flush is already in flight.
  void tryFlush() {
    if (_isFlushing) return;
    _isFlushing = true;
    NativeBridge.flush().whenComplete(() => _isFlushing = false);
  }

  void dispose() {
    _syncEventSub?.cancel();
    _syncEventSub = null;
    unawaited(_stopIosStream());
  }

  // ── iOS foreground stream ──────────────────────────────────────────────

  Future<void> _startIosStream() async {
    if (_iosPositionStream != null) return;

    await LocationCache.load();
    _isStarting = true;

    // Hardware pre-filter uses the walking-minimum distance; the adaptive
    // (speed-based) threshold in [AdaptiveLocationFilter] applies on top,
    // so a cycling/driving fix is never over-suppressed at the OS level.
    const iosHardwareDistFilter = 15;

    final locationSettings = AppleSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      activityType: geo.ActivityType.otherNavigation,
      distanceFilter: iosHardwareDistFilter,
      pauseLocationUpdatesAutomatically: false,
      allowBackgroundLocationUpdates: true,
      showBackgroundLocationIndicator: false,
    );

    _iosPositionStream = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      _onLocation,
      onError: (Object e) => _log('[iOS] stream error: $e'),
      cancelOnError: false,
    );

    // Startup lock: ignore fixes during the GPS warm-up window so a stale
    // last-known fix doesn't get treated as a fresh sample.
    await Future.delayed(const Duration(seconds: 5));
    _isStarting = false;
  }

  Future<void> _stopIosStream() async {
    await _iosPositionStream?.cancel();
    _iosPositionStream = null;
  }

  Future<void> _onLocation(Position position) async {
    if (_isStarting) return;

    // Ownership gate: if the native layer owns capture (app backgrounded),
    // drop this fix -- the native service is already handling it and we
    // must not double-send.
    final currentOwner = await LocationFilterConfig.owner;
    if (currentOwner != LocationFilterConfig.kOwnerFlutter) return;

    try {
      final shouldSend = await _filter.shouldSend(position);
      if (!shouldSend) return;

      await _sendLocation(position);
      await _flushIfNeeded();
    } catch (e) {
      _log('_onLocation error: $e');
    }
  }

  Future<void> _sendLocation(Position position) async {
    int? batteryLevel;
    try {
      batteryLevel = await Battery().batteryLevel;
    } catch (_) {}

    final fix = LocationFix.fromPosition(position, batteryLevel: batteryLevel);

    try {
      final result = await _config.onSend(fix);
      if (result.isSuccess) {
        _consecutiveFailures = 0;
        await LocationFilterConfig.setDegradedMode(false);
        await LocationCache.save(position);
      } else {
        await _handleSendFailure();
        // Client can't be reached from here to persist offline on iOS --
        // the native kill-survival service is the one responsible for
        // offline persistence once it owns capture. A repeated foreground
        // failure just stays in degraded mode until connectivity returns.
      }
    } catch (e) {
      _log('_sendLocation failed: $e');
      await _handleSendFailure();
    }
  }

  Future<void> _handleSendFailure() async {
    _consecutiveFailures++;
    if (_consecutiveFailures >= LocationFilterConfig.degradedFailureThreshold) {
      final alreadyDegraded = await LocationFilterConfig.isDegradedMode;
      if (!alreadyDegraded) {
        await LocationFilterConfig.setDegradedMode(true);
        _log('degraded mode activated after $_consecutiveFailures failures');
      }
    }
  }

  Future<void> _flushIfNeeded() async {
    if (_isFlushing) return;
    final nativeIsFlushing = await LocationFilterConfig.isFlushing;
    if (nativeIsFlushing) return;
    _isFlushing = true;
    try {
      await NativeBridge.flush();
    } finally {
      _isFlushing = false;
    }
  }

  Future<bool> _ensurePermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    return perm == LocationPermission.always ||
        perm == LocationPermission.whileInUse;
  }

  void _log(String message) => _config.onLog?.call('[AdaptiveLocationTracker] $message');
}
