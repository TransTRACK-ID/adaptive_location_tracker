# Migration guide

## 1. Add the dependency

```yaml
dependencies:
  adaptive_location_tracker:
    git:
      url: https://github.com/your-org/adaptive_location_tracker.git
      ref: main
```

## 2. Android host-app setup

The plugin's own `AndroidManifest.xml` declares the service, receiver, and
required permissions -- these merge into your app automatically via AGP's
manifest merger. You still need to, in your **own** app:

- Request runtime permissions (`ACCESS_FINE_LOCATION`, then separately
  `ACCESS_BACKGROUND_LOCATION` on Android 10+) before calling
  `AdaptiveLocationTracker.start()`. The package's own permission check
  (`Geolocator.checkPermission`/`requestPermission`) only requests
  foreground permission -- background permission needs its own OS-level
  flow with a rationale screen, which is inherently app-specific UX.
- Implement `ensureAndroidBatteryExemption` if you want to enforce the
  battery-optimization exemption (recommended for reliable background
  tracking on OEM skins like Xiaomi/Oppo/Vivo that aggressively kill
  background services).

## 3. iOS host-app setup

Add to `ios/Runner/Info.plist`:

```xml
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>We use your location to track deliveries in progress.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>We use your location to track deliveries in progress.</string>
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
    <string>fetch</string>
    <string>processing</string>
</array>
```

No AppDelegate.swift changes are required -- `AdaptiveLocationTrackerPlugin` registers
its method/event channels and the cold-launch relaunch hook automatically
via Flutter's standard plugin registration
(`GeneratedPluginRegistrant.register(with: self)`, already present in every
Flutter iOS project).

## 4. Wiring an existing app (e.g. this one)

Where the old app had:

```dart
class TrackingServiceController {
  Future<void> syncWithHome(Home home) async {
    // ... start/stop BackgroundLocatorHelper + KillSurvivalService directly
  }
}
```

it now becomes a thin layer that decides *when* to call the package,
translating your own domain state (attendance/task status) into
`AdaptiveLocationTracker.start()`/`stop()` calls -- see `example/` and the reference
diff in this repo's PR description for the full before/after.

Callback mapping cheat-sheet (old -> new):

| Old (app-specific)                                   | New (package callback)                  |
|-------------------------------------------------------|------------------------------------------|
| `MirrorRepository().sentData(position)`               | `AdaptiveLocationTrackerConfig.onSend`               |
| `FlashMessageHelper` (sync toasts)                     | `AdaptiveLocationTrackerConfig.onSyncEvent`          |
| `LogHelper.writeToLogFile(...)`                        | `AdaptiveLocationTrackerConfig.onLog`                |
| `BatteryOptGate.ensureExemption()`                     | `AdaptiveLocationTrackerConfig.ensureAndroidBatteryExemption` |
| `kTrackingUrl` + `secureStorage.read(kPhoneNumber)`    | `NativeEndpointConfig(trackingUrl:, subjectId:)` |

## 5. Verifying the native build

This package's native Android/iOS source was ported by hand (no Flutter/Gradle/
Xcode toolchain was available in the environment that generated it). Before
shipping:

- `flutter pub get` in a real project with this as a path/git dependency,
  then a full `flutter build apk` / `flutter build ios` to catch any Gradle
  or CocoaPods wiring issues.
- Smoke-test on a real device: foreground tracking, background tracking,
  force-kill + significant location change relaunch (iOS), and offline queue
  flush on reconnect, on both platforms.
