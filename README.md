# adaptive_location_tracker

Cross-platform (Android + iOS) live location tracking, extracted from a
production app into a reusable, private git-hosted Flutter package.

- Adaptive, speed-based send filtering (stationary / walking / cycling / driving)
- Android: a real foreground service (FusedLocationProviderClient + SQLite offline queue)
- iOS: a kill-survival background service (significant-change wake + CoreMotion
  activity recognition + SQLite offline queue)
- Degraded-mode backoff after repeated send failures
- Your backend and UI are wired in via simple callbacks -- no assumptions
  about your API shape beyond a query-string POST endpoint (configurable
  field names)

## Install (private git dependency)

```yaml
dependencies:
  adaptive_location_tracker:
    git:
      url: https://github.com/your-org/adaptive_location_tracker.git
      ref: main   # pin to a tag/commit for production
```

## Usage

```dart
import 'package:adaptive_location_tracker/adaptive_location_tracker.dart';

await AdaptiveLocationTracker.configure(
  AdaptiveLocationTrackerConfig(
    // Called whenever the Flutter engine is alive and a fix passes the
    // adaptive filter (iOS foreground stream, legacy-queue flush path).
    onSend: (fix) async {
      try {
        final response = await myApi.postLocation(fix);
        return response.isSuccess
            ? const SendResult.success()
            : (response.isClientError
                ? const SendResult.discard()
                : const SendResult.retryableFailure());
      } catch (_) {
        return const SendResult.retryableFailure();
      }
    },

    // Required even if your backend is only ever hit from Dart today --
    // this is what keeps tracking alive when the app is backgrounded/killed.
    native: NativeEndpointConfig(
      trackingUrl: 'https://your-backend.example/api/location',
      subjectId: currentUserId,
      // Override if your backend uses different query param names:
      // fieldKeys: NativeFieldKeys(subjectId: 'user_id', latitude: 'lat', ...),
    ),

    onLog: (msg) => myLogger.d(msg),
    onSyncEvent: (event) {
      if (event.type == TrackingSyncEventType.end && event.sent > 0) {
        myToast.show('${event.sent} offline points synced');
      }
    },

    // Android only -- return true once exempted (or skip enforcing it).
    ensureAndroidBatteryExemption: () => myBatteryOptDialogFlow.ensureExemption(),
  ),
);

final result = await AdaptiveLocationTracker.start();
switch (result) {
  case StartResult.started:
    break;
  case StartResult.permissionDenied:
    // show your own explanation UI
    break;
  case StartResult.androidBatteryExemptionDenied:
    break;
}

// ... later
await AdaptiveLocationTracker.stop();

// On foreground resume, ask the native layer to drain its offline queue:
AdaptiveLocationTracker.tryFlush();
```

## Required host-app setup

This package still needs a few manual entries in the host app -- normal for
any plugin doing foreground/background location work. See `MIGRATION.md`.

## What's intentionally NOT abstracted

- The HTTP transport contract is a **query-string POST**. If your backend
  needs a JSON body, headers-based auth, etc., the native senders
  (`LocationTrackingService.kt` / `KillSurvivalLocationService.m`) need a
  small patch -- this is the one place a fork-and-modify is expected for v1.
- Notification content/icon for the Android foreground service is fixed in
  v1. A `NotificationConfig` hook is a natural v2 addition.
