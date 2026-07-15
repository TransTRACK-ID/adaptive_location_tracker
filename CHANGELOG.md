## 0.1.1

- Fix (Android): live fixes that fail to send are now always queued for
  retry, regardless of altitude/vertical-accuracy. The previous check
  discarded WiFi/cell-assisted fixes with `altitude == 0` and no barometric
  reading -- routinely true on entry-level devices without a barometer --
  meaning failed sends on those devices were silently lost instead of
  retried. Now matches the iOS kill-survival service and the offline-flush
  path, which already queue/retry unconditionally.

## 0.1.0

Initial extraction from the mytask app's live-tracking flow:
- Adaptive speed-based filter (Dart)
- Android foreground tracking service (Kotlin)
- iOS kill-survival background service (Objective-C) + Swift plugin registrant
- Generic native HTTP sender with configurable field-key names
- Degraded-mode backoff, offline SQLite queue on both platforms
