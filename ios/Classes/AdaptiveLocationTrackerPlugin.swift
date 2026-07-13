import Flutter
import UIKit

/// Flutter <-> ObjC bridge for [KillSurvivalLocationService].
///
/// A standard `FlutterPlugin`, registered automatically via
/// `GeneratedPluginRegistrant` (no manual AppDelegate wiring needed) --
/// including the `didFinishLaunchingWithOptions` relaunch hook, via
/// `registrar.addApplicationDelegate(self)`.
///
/// Channel names match `native_bridge.dart` / the Android `AdaptiveLocationTrackerPlugin`
/// exactly so the same Dart code works unmodified on either platform.
public class AdaptiveLocationTrackerPlugin: NSObject, FlutterPlugin {

    private static let methodChannelName = "dev.adaptive_location_tracker/channel"
    private static let eventChannelName = "dev.adaptive_location_tracker/sync_events"

    private var syncEventSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = AdaptiveLocationTrackerPlugin()

        let methodChannel = FlutterMethodChannel(
            name: methodChannelName,
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let eventChannel = FlutterEventChannel(
            name: eventChannelName,
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(instance)

        // Forwards application(_:didFinishLaunchingWithOptions:) so a
        // significant-location-change relaunch can restart the watcher
        // before the Flutter engine is necessarily ready -- the host app's
        // AppDelegate doesn't need any extra code for this.
        registrar.addApplicationDelegate(instance)

        NotificationCenter.default.addObserver(
            instance,
            selector: #selector(handleFlushBegin(_:)),
            name: NSNotification.Name("KSAutoFlushDidBegin"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            instance,
            selector: #selector(handleFlushEnd(_:)),
            name: NSNotification.Name("KSAutoFlushDidEnd"),
            object: nil
        )
    }

    // MARK: - App lifecycle (cold-launch relaunch via significant location change)

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any] = [:]
    ) -> Bool {
        if launchOptions[.location] != nil {
            KillSurvivalLocationService.shared().startWatchingForKill()
        }
        return true
    }

    // MARK: - MethodChannel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "start":
            KillSurvivalLocationService.shared().startWatchingForKill()
            result(nil)

        case "stop":
            KillSurvivalLocationService.shared().stopWatching()
            LocationQueue.shared().clear()
            result(nil)

        case "setTrackingConfig":
            if let args = call.arguments as? [String: Any],
               let url = args["url"] as? String,
               let subjectId = args["subjectId"] as? String {
                let fieldKeys = args["fieldKeys"] as? [String: String] ?? [:]
                KillSurvivalLocationService.shared().setTrackingURL(
                    url, subjectId: subjectId, fieldKeys: fieldKeys)
            }
            result(nil)

        case "flush":
            KillSurvivalLocationService.shared().requestFlush()
            result(nil)

        case "getQueue":
            result(LocationQueue.shared().dequeueAll())

        case "deleteEntry":
            if let args = call.arguments as? [String: Any],
               let entryId = args["id"] as? Int {
                LocationQueue.shared().deleteEntry(withId: entryId)
            }
            result(nil)

        case "readLog":
            result("")

        case "clearLog":
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Notification relays

    @objc private func handleFlushBegin(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let sink = self?.syncEventSink else { return }
            let count = (notification.object as? NSNumber)?.intValue ?? 0
            sink(["type": "begin", "count": count])
        }
    }

    @objc private func handleFlushEnd(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let sink = self?.syncEventSink else { return }
            let parts = notification.object as? [NSNumber] ?? []
            sink([
                "type": "end",
                "sent": parts.count > 0 ? parts[0].intValue : 0,
                "kept": parts.count > 1 ? parts[1].intValue : 0,
                "discarded": parts.count > 2 ? parts[2].intValue : 0,
            ])
        }
    }
}

extension AdaptiveLocationTrackerPlugin: FlutterStreamHandler {
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        syncEventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        syncEventSink = nil
        return nil
    }
}
