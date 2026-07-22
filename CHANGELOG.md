## 0.1.4

- AdaptiveLocationTracker.configure() unconditionally disposed and
  recreated the controller instance, but dispose() never called
  NativeBridge.stop() -- so calling configure()/start() again while a
  session was already active (e.g. app calls registerOnLocationChanged()
  for a second concurrently-running task) left the native foreground
  service/kill-survival session running and then re-armed it via a
  second native `start` invocation, with no dedup on either side.

  - AdaptiveLocationTrackerController: track _isTracking; start() is now
    a no-op success if already tracking; stop() clears the flag; expose
    isTracking getter.
  - AdaptiveLocationTracker (static facade): configure() now stops any
    active session on the current instance before disposing/recreating
    it, instead of relying on callers to remember to call stop() first.
    Exposes AdaptiveLocationTracker.isTracking.

  No public API removed; StartResult and method signatures unchanged.

## 0.1.3

- Fix (Android): the queue flush no longer starts -- and no longer fires
  the "sync begin" event -- while the device has no connection.
  `flushQueue()` was reachable from triggers that run regardless of
  connectivity (the heartbeat interval, `onLocationAvailability`,
  `ACTION_FLUSH`, service restart), so a flush attempt -- and the
  resulting host-app "syncing N offline locations" notice -- could
  surface even though the device was offline and nothing was actually
  being sent. Android now checks connectivity first and leaves queued
  rows untouched until a real connectivity-restore callback fires.

## 0.1.2

- Fix (Android): coordinate/speed/bearing/altitude/accuracy values sent to the
  tracking endpoint were formatted with `String.format` using the device's
  *default* locale instead of a fixed one. On devices whose system language
  uses a comma as the decimal separator (e.g. Indonesian, German, many
  others), this produced malformed query params like `lat=-6,914744` instead
  of `lat=-6.914744`. Backends that can't parse a comma-decimal float then
  error, which surfaces to the client as an upstream/gateway error (e.g.
  Cloudflare 502) that looks like a flaky network rather than a malformed
  request. All native numeric formatting is now pinned to `Locale.US`,
  matching the date formatting in the same file (which was already pinned
  correctly) and the iOS sender (Objective-C's `stringWithFormat` is
  locale-independent for `%f`, so iOS was never affected). This also matches
  Dart's own number-to-string conversion, which is locale-independent --
  explaining why the bug only appeared after location posts moved from the
  Dio/Dart path to the native Android background-service path.

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
