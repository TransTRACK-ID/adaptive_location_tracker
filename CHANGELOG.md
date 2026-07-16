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
